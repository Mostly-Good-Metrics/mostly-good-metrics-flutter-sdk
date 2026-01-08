import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'logger.dart';
import 'network.dart';
import 'storage.dart';
import 'types.dart';
import 'utils.dart';

/// The main MostlyGoodMetrics SDK class.
///
/// This is a singleton class that manages event tracking, user identification,
/// and automatic event flushing.
///
/// Example:
/// ```dart
/// // Initialize the SDK
/// await MostlyGoodMetrics.configure(
///   MGMConfiguration(apiKey: 'your-api-key'),
/// );
///
/// // Track an event
/// MostlyGoodMetrics.track('button_clicked', properties: {'button_id': 'signup'});
///
/// // Identify a user
/// MostlyGoodMetrics.identify('user-123');
/// ```
class MostlyGoodMetrics with WidgetsBindingObserver {
  static MostlyGoodMetrics? _instance;
  static bool _isConfigured = false;

  MGMConfiguration? _config;
  EventStorage? _eventStorage;
  StateStorage? _stateStorage;
  NetworkClient? _networkClient;
  Timer? _flushTimer;

  String? _userId;
  String? _anonymousId;
  String? _sessionId;
  bool _isAppInForeground = true;

  // Experiments cache
  List<Experiment> _experiments = [];
  bool _experimentsLoaded = false;

  // Storage keys
  static const String _userIdKey = 'userId';
  static const String _anonymousIdKey = 'anonymousId';
  static const String _sessionIdKey = 'sessionId';
  static const String _appVersionKey = 'appVersion';
  static const String _superPropertiesKey = 'superProperties';
  static const String _identifyHashKey = 'identifyHash';
  static const String _identifyTimestampKey = 'identifyTimestamp';

  // 24 hours in milliseconds
  static const int _twentyFourHoursMs = 24 * 60 * 60 * 1000;

  /// The effective user ID to use in events (identified user or anonymous).
  String? get _effectiveUserId => _userId ?? _anonymousId;

  // In-memory cache for super properties
  Map<String, dynamic> _superProperties = {};

  MostlyGoodMetrics._internal();

  /// Get the shared instance of MostlyGoodMetrics.
  static MostlyGoodMetrics get instance {
    _instance ??= MostlyGoodMetrics._internal();
    return _instance!;
  }

  /// Check if the SDK has been configured.
  static bool get isConfigured => _isConfigured;

  /// Configure the SDK with the given configuration.
  ///
  /// This must be called before any other SDK methods.
  /// It's safe to call this multiple times - subsequent calls will
  /// reconfigure the SDK.
  static Future<void> configure(
    MGMConfiguration config, {
    EventStorage? eventStorage,
    StateStorage? stateStorage,
    NetworkClient? networkClient,
  }) async {
    final mgm = instance;

    // Stop existing timer
    mgm._flushTimer?.cancel();

    // Remove existing observer
    if (_isConfigured) {
      WidgetsBinding.instance.removeObserver(mgm);
    }

    mgm._config = config;
    MGMLogger.setEnabled(config.enableDebugLogging);

    MGMLogger.debug('Configuring MostlyGoodMetrics SDK');

    // Initialize storage
    mgm._eventStorage = eventStorage ??
        FileEventStorage(maxStoredEvents: config.maxStoredEvents);
    mgm._stateStorage = stateStorage ?? PreferencesStateStorage();
    mgm._networkClient = networkClient ?? HttpNetworkClient();

    // Restore persisted state
    await mgm._restoreState();

    // Start new session
    mgm._sessionId = MGMUtils.generateUUID();
    await mgm._stateStorage!.setString(_sessionIdKey, mgm._sessionId);

    // Start flush timer
    mgm._startFlushTimer();

    // Add lifecycle observer
    WidgetsBinding.instance.addObserver(mgm);

    // Mark as configured before tracking any events
    _isConfigured = true;

    // Fetch experiments asynchronously (don't block configure)
    mgm._fetchExperimentsAsync();

    // Check for app version changes (may track $app_installed or $app_updated)
    await mgm._checkAppVersionChange();

    // Track app opened
    if (config.trackAppLifecycleEvents) {
      track(r'$app_opened');
    }

    MGMLogger.debug('MostlyGoodMetrics SDK configured successfully');
  }

  Future<void> _restoreState() async {
    _userId = await _stateStorage!.getString(_userIdKey);
    MGMLogger.debug('Restored userId: $_userId');

    // Restore or generate anonymous ID
    _anonymousId = await _stateStorage!.getString(_anonymousIdKey);
    if (_anonymousId == null) {
      _anonymousId = MGMUtils.generateAnonymousId();
      await _stateStorage!.setString(_anonymousIdKey, _anonymousId);
      MGMLogger.debug('Generated new anonymousId: $_anonymousId');
    } else {
      MGMLogger.debug('Restored anonymousId: $_anonymousId');
    }

    // Restore super properties
    final superPropsJson = await _stateStorage!.getString(_superPropertiesKey);
    if (superPropsJson != null) {
      try {
        _superProperties =
            Map<String, dynamic>.from(json.decode(superPropsJson) as Map);
        MGMLogger.debug(
          'Restored super properties: ${_superProperties.keys.join(', ')}',
        );
      } catch (e) {
        MGMLogger.warning('Failed to restore super properties: $e');
        _superProperties = {};
      }
    }
  }

  Future<void> _checkAppVersionChange() async {
    if (_config?.appVersion == null) return;

    final storedVersion = await _stateStorage!.getString(_appVersionKey);
    final currentVersion = _config!.appVersion;

    if (storedVersion == null) {
      // First install
      if (_config!.trackAppLifecycleEvents) {
        track(r'$app_installed');
      }
    } else if (storedVersion != currentVersion) {
      // App updated
      if (_config!.trackAppLifecycleEvents) {
        track(
          r'$app_updated',
          properties: {
            'previous_version': storedVersion,
            'current_version': currentVersion,
          },
        );
      }
    }

    await _stateStorage!.setString(_appVersionKey, currentVersion);
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      Duration(seconds: _config!.flushInterval),
      (_) => _flushEvents(),
    );
  }

  /// Track an analytics event.
  ///
  /// The [name] must be a valid event name (alphanumeric and underscores,
  /// starting with a letter or $).
  ///
  /// Optional [properties] can be provided as a map of key-value pairs.
  /// Properties can be nested up to 3 levels deep.
  ///
  /// Super properties are automatically merged with event properties.
  /// Event properties override super properties if there's a key conflict.
  ///
  /// Throws [MGMError] if the SDK is not configured or if validation fails.
  static void track(String name, {Map<String, dynamic>? properties}) {
    _ensureConfigured();

    final mgm = instance;

    // Validate event name
    final nameError = MGMUtils.validateEventName(name);
    if (nameError != null) {
      throw MGMError(
        type: MGMErrorType.invalidEventName,
        message: nameError,
      );
    }

    // Merge properties: super properties < event properties
    // Event properties override super properties
    final mergedProperties = <String, dynamic>{
      ...mgm._superProperties,
      if (properties != null) ...properties,
    };

    // Validate merged properties
    final propsError = MGMUtils.validateProperties(
      mergedProperties.isEmpty ? null : mergedProperties,
    );
    if (propsError != null) {
      throw MGMError(
        type: MGMErrorType.invalidProperties,
        message: propsError,
      );
    }

    final event = MGMEvent(
      name: name,
      clientEventId: MGMUtils.generateUUID(),
      timestamp: DateTime.now(),
      userId: mgm._effectiveUserId,
      sessionId: mgm._sessionId,
      platform: MGMUtils.getPlatformName(),
      appVersion: mgm._config!.appVersion,
      osVersion: MGMUtils.getOSVersion(),
      environment: mgm._config!.environment,
      deviceManufacturer: MGMUtils.getDeviceManufacturer(),
      locale: MGMUtils.getLocale(),
      timezone: MGMUtils.getTimezone(),
      properties: mergedProperties.isEmpty ? null : mergedProperties,
    );

    mgm._eventStorage!.store(event);
    MGMLogger.debug('Tracked event: $name');
  }

  /// Identify the current user with optional profile data.
  ///
  /// The [userId] will be attached to all subsequent events until
  /// [resetIdentity] is called.
  ///
  /// Optional [profile] data (email, name) is sent to the backend via the
  /// $identify event. Debouncing: only sends $identify if payload changed
  /// or >24h since last send.
  static Future<void> identify(String userId, {UserProfile? profile}) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._userId = userId;
    await mgm._stateStorage!.setString(_userIdKey, userId);
    MGMLogger.debug('Identified user: $userId');

    // If profile data is provided, check if we should send $identify event
    if (profile != null && (profile.email != null || profile.name != null)) {
      await mgm._sendIdentifyEventIfNeeded(userId, profile);
    }
  }

  /// Send $identify event if debounce conditions are met.
  /// Only sends if: hash changed OR more than 24 hours since last send.
  Future<void> _sendIdentifyEventIfNeeded(
    String userId,
    UserProfile profile,
  ) async {
    final currentHash = _computeIdentifyHash(userId, profile);
    final storedHash = await _stateStorage!.getString(_identifyHashKey);
    final lastSentAtStr = await _stateStorage!.getString(_identifyTimestampKey);
    final lastSentAt =
        lastSentAtStr != null ? int.tryParse(lastSentAtStr) : null;
    final now = DateTime.now().millisecondsSinceEpoch;

    final hashChanged = storedHash != currentHash;
    final expiredTime =
        lastSentAt == null || (now - lastSentAt) > _twentyFourHoursMs;

    if (hashChanged || expiredTime) {
      MGMLogger.debug(
        r'Sending $identify event (hashChanged=$hashChanged, expiredTime=$expiredTime)',
      );

      // Build properties with only defined values
      final properties = <String, dynamic>{};
      if (profile.email != null) {
        properties['email'] = profile.email;
      }
      if (profile.name != null) {
        properties['name'] = profile.name;
      }

      // Track the $identify event
      track(r'$identify', properties: properties);

      // Update stored hash and timestamp
      await _stateStorage!.setString(_identifyHashKey, currentHash);
      await _stateStorage!.setString(_identifyTimestampKey, now.toString());
    } else {
      MGMLogger.debug(r'Skipping $identify event (debounced)');
    }
  }

  /// Compute a simple hash for debouncing identify calls.
  String _computeIdentifyHash(String userId, UserProfile profile) {
    final payload = '$userId|${profile.email ?? ''}|${profile.name ?? ''}';
    var hash = 0;
    for (var i = 0; i < payload.length; i++) {
      hash = ((hash << 5) - hash) + payload.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF; // Convert to 32-bit integer
    }
    return hash.toRadixString(16);
  }

  /// Clear identify debounce state.
  Future<void> _clearIdentifyState() async {
    await _stateStorage!.setString(_identifyHashKey, null);
    await _stateStorage!.setString(_identifyTimestampKey, null);
  }

  /// Reset the current user identity.
  ///
  /// This clears the userId, identify debounce state, and starts a new session.
  static Future<void> resetIdentity() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._userId = null;
    await mgm._stateStorage!.setString(_userIdKey, null);
    await mgm._clearIdentifyState();

    // Start new session
    mgm._sessionId = MGMUtils.generateUUID();
    await mgm._stateStorage!.setString(_sessionIdKey, mgm._sessionId);

    MGMLogger.debug('Identity reset');
  }

  /// Start a new session.
  ///
  /// This generates a new session ID that will be attached to all
  /// subsequent events.
  static Future<void> startNewSession() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._sessionId = MGMUtils.generateUUID();
    await mgm._stateStorage!.setString(_sessionIdKey, mgm._sessionId);
    MGMLogger.debug('Started new session: ${mgm._sessionId}');
  }

  // Super Properties

  /// Set a single super property that will be included with every event.
  ///
  /// Super properties are persisted across app launches.
  static Future<void> setSuperProperty(String key, dynamic value) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._superProperties[key] = value;
    await mgm._saveSuperProperties();
    MGMLogger.debug('Set super property: $key');
  }

  /// Set multiple super properties at once.
  ///
  /// Super properties are persisted across app launches.
  static Future<void> setSuperProperties(
    Map<String, dynamic> properties,
  ) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._superProperties.addAll(properties);
    await mgm._saveSuperProperties();
    MGMLogger.debug('Set super properties: ${properties.keys.join(', ')}');
  }

  /// Remove a single super property.
  static Future<void> removeSuperProperty(String key) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._superProperties.remove(key);
    await mgm._saveSuperProperties();
    MGMLogger.debug('Removed super property: $key');
  }

  /// Clear all super properties.
  static Future<void> clearSuperProperties() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._superProperties.clear();
    await mgm._stateStorage!.setString(_superPropertiesKey, null);
    MGMLogger.debug('Cleared all super properties');
  }

  /// Get all current super properties.
  static Map<String, dynamic> getSuperProperties() {
    _ensureConfigured();
    return Map<String, dynamic>.from(instance._superProperties);
  }

  Future<void> _saveSuperProperties() async {
    final json = jsonEncode(_superProperties);
    await _stateStorage!.setString(_superPropertiesKey, json);
  }

  // Experiments / A/B Testing

  /// Fetch experiments asynchronously (called during configure).
  void _fetchExperimentsAsync() {
    _networkClient!.fetchExperiments(_config!).then((experiments) {
      _experiments = experiments;
      _experimentsLoaded = true;
      MGMLogger.debug('Loaded ${experiments.length} experiments');
    }).catchError((e) {
      MGMLogger.warning('Failed to fetch experiments: $e');
      _experimentsLoaded = true; // Mark as loaded even on failure
    });
  }

  /// Get the variant for an experiment.
  ///
  /// Returns the assigned variant string ('a', 'b', etc.) or null if the
  /// experiment doesn't exist.
  ///
  /// The variant assignment is deterministic based on a hash of the user ID
  /// and experiment name, ensuring the same user always gets the same variant.
  ///
  /// The assigned variant is automatically stored as a super property with
  /// the key `experiment_{experimentName}` (snake_case).
  ///
  /// If experiments haven't been fetched yet, falls back to hash-based
  /// assignment using 2 variants ('a', 'b').
  static String? getVariant(String experimentName) {
    _ensureConfigured();

    final mgm = instance;

    // Check if we already have this variant assigned as a super property
    final superPropertyKey = 'experiment_${_toSnakeCase(experimentName)}';
    final existingVariant = mgm._superProperties[superPropertyKey] as String?;
    if (existingVariant != null) {
      return existingVariant;
    }

    // Find the experiment
    Experiment? experiment;
    for (final exp in mgm._experiments) {
      if (exp.id == experimentName) {
        experiment = exp;
        break;
      }
    }

    List<String> variants;
    if (experiment != null) {
      variants = experiment.variants;
    } else if (!mgm._experimentsLoaded) {
      // Fallback: experiments not yet loaded, use default 2 variants
      MGMLogger.debug(
        'Experiments not loaded yet, using fallback variants for $experimentName',
      );
      variants = ['a', 'b'];
    } else {
      // Experiment doesn't exist
      MGMLogger.debug('Experiment "$experimentName" not found');
      return null;
    }

    if (variants.isEmpty) {
      return null;
    }

    // Compute deterministic variant assignment
    final userId = mgm._effectiveUserId ?? '';
    final hash = _computeVariantHash(userId, experimentName);
    final variantIndex = hash % variants.length;
    final variant = variants[variantIndex];

    // Store as super property
    setSuperProperty(superPropertyKey, variant);

    MGMLogger.debug(
      'Assigned variant "$variant" for experiment "$experimentName"',
    );

    return variant;
  }

  /// Compute a deterministic hash for variant assignment.
  static int _computeVariantHash(String userId, String experimentName) {
    final input = '$userId|$experimentName';
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash = hash & 0x7FFFFFFF; // Keep positive 31-bit integer
    }
    return hash;
  }

  /// Convert a string to snake_case.
  static String _toSnakeCase(String input) {
    return input
        .replaceAllMapped(
          RegExp(r'([A-Z])'),
          (match) => '_${match.group(1)!.toLowerCase()}',
        )
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '')
        .toLowerCase();
  }

  /// Flush pending events to the server.
  ///
  /// This is called automatically based on the [flushInterval] configuration,
  /// but can be called manually to force an immediate flush.
  static Future<void> flush() async {
    _ensureConfigured();
    await instance._flushEvents();
  }

  /// Get the number of pending events.
  static Future<int> getPendingEventCount() async {
    _ensureConfigured();
    return instance._eventStorage!.eventCount();
  }

  /// Clear all pending events.
  ///
  /// Use with caution - this will delete all events that haven't been
  /// sent to the server yet.
  static Future<void> clearPendingEvents() async {
    _ensureConfigured();
    await instance._eventStorage!.clear();
    MGMLogger.debug('Cleared pending events');
  }

  /// Get the current user ID, if set.
  static String? get userId {
    _ensureConfigured();
    return instance._userId;
  }

  /// Get the anonymous ID.
  /// This is auto-generated and persisted across app launches.
  /// Format: $anon_xxxxxxxxxxxx (12 random alphanumeric chars)
  static String? get anonymousId {
    _ensureConfigured();
    return instance._anonymousId;
  }

  /// Get the current session ID.
  static String? get sessionId {
    _ensureConfigured();
    return instance._sessionId;
  }

  Future<void> _flushEvents() async {
    final eventCount = await _eventStorage!.eventCount();
    if (eventCount == 0) {
      MGMLogger.debug('No events to flush');
      return;
    }

    if (_networkClient!.isRateLimited()) {
      MGMLogger.debug('Rate limited, skipping flush');
      return;
    }

    final batchSize = _config!.maxBatchSize;
    final events = await _eventStorage!.fetchEvents(batchSize);

    if (events.isEmpty) return;

    MGMLogger.debug('Flushing ${events.length} events');

    final payload = EventsPayload(
      events: events,
      context: EventContext(
        platform: MGMUtils.getPlatformName(),
        appVersion: _config!.appVersion,
        osVersion: MGMUtils.getOSVersion(),
        userId: _effectiveUserId,
        sessionId: _sessionId,
        environment: _config!.environment,
        deviceManufacturer: MGMUtils.getDeviceManufacturer(),
        locale: MGMUtils.getLocale(),
        timezone: MGMUtils.getTimezone(),
      ),
    );

    final result = await _networkClient!.sendEvents(payload, _config!);

    switch (result) {
      case SendResult.success:
        await _eventStorage!.removeEvents(events.length);
        MGMLogger.debug('Successfully sent ${events.length} events');
        break;
      case SendResult.partialSuccess:
        // Some events may have been sent, but we don't know which
        // Keep events for retry
        MGMLogger.warning('Partial success sending events');
        break;
      case SendResult.failure:
        // Keep events for retry
        MGMLogger.warning('Failed to send events, will retry');
        break;
      case SendResult.rateLimited:
        // Keep events for retry after rate limit expires
        MGMLogger.warning('Rate limited, will retry later');
        break;
    }
  }

  static void _ensureConfigured() {
    if (!_isConfigured) {
      throw const MGMError(
        type: MGMErrorType.notConfigured,
        message: 'MostlyGoodMetrics SDK has not been configured. '
            'Call MostlyGoodMetrics.configure() first.',
      );
    }
  }

  // WidgetsBindingObserver methods

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isConfigured || _config == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isAppInForeground) {
          _isAppInForeground = true;
          if (_config!.trackAppLifecycleEvents) {
            track(r'$app_foregrounded');
          }
          // Restart flush timer
          _startFlushTimer();
        }
        break;
      case AppLifecycleState.paused:
        if (_isAppInForeground) {
          _isAppInForeground = false;
          if (_config!.trackAppLifecycleEvents) {
            track(r'$app_backgrounded');
          }
          // Flush events before going to background
          _flushEvents();
          // Stop flush timer while in background
          _flushTimer?.cancel();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  /// Reset the SDK state (for testing only).
  static void reset() {
    if (_instance != null) {
      _instance!._flushTimer?.cancel();
      _instance!._experiments = [];
      _instance!._experimentsLoaded = false;
      WidgetsBinding.instance.removeObserver(_instance!);
    }
    _instance = null;
    _isConfigured = false;
  }
}
