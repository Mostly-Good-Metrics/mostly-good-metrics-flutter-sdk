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

  // Storage keys
  static const String _userIdKey = 'userId';
  static const String _anonymousIdKey = 'anonymousId';
  static const String _sessionIdKey = 'sessionId';
  static const String _appVersionKey = 'appVersion';
  static const String _superPropertiesKey = 'superProperties';
  static const String _identifyHashKey = 'identifyHash';
  static const String _identifyTimestampKey = 'identifyTimestamp';
  static const String _experimentsKey = 'experiments';
  static const String _experimentsUserIdKey = 'experimentsUserId';
  static const String _experimentsFetchedAtKey = 'experimentsFetchedAt';

  // 24 hours in milliseconds
  static const int _twentyFourHoursMs = 24 * 60 * 60 * 1000;

  /// The effective user ID to use in events (identified user or anonymous).
  String? get _effectiveUserId => _userId ?? _anonymousId;

  // In-memory cache for super properties
  Map<String, dynamic> _superProperties = {};

  // A/B testing state
  Map<String, String> _assignedVariants = {};
  Completer<void>? _experimentsReadyCompleter;
  bool _experimentsLoaded = false;

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

    // Check for app version changes (may track $app_installed or $app_updated)
    await mgm._checkAppVersionChange();

    // Track app opened
    if (config.trackAppLifecycleEvents) {
      track(r'$app_opened');
    }

    // Initialize experiments (async, don't block configure)
    mgm._initializeExperiments();

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
  ///
  /// If the user ID changes, the experiments cache is invalidated and
  /// experiments are refetched for the new user.
  static Future<void> identify(String userId, {UserProfile? profile}) async {
    _ensureConfigured();

    final mgm = instance;
    final previousUserId = mgm._userId;
    mgm._userId = userId;
    await mgm._stateStorage!.setString(_userIdKey, userId);
    MGMLogger.debug('Identified user: $userId');

    // If user changed, invalidate experiments cache and refetch
    if (previousUserId != userId) {
      await mgm._clearExperimentsCache();
      mgm._assignedVariants = {};
      mgm._experimentsLoaded = false;
      // Refetch experiments for new user
      mgm._initializeExperiments();
    }

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
    final jsonStr = jsonEncode(_superProperties);
    await _stateStorage!.setString(_superPropertiesKey, jsonStr);
  }

  // A/B Testing Methods

  /// Initialize experiments - fetch from server or restore from cache.
  Future<void> _initializeExperiments() async {
    _experimentsReadyCompleter = Completer<void>();
    _experimentsLoaded = false;

    try {
      // Try to restore from cache first
      final cachedExperiments = await _restoreExperimentsFromCache();
      if (cachedExperiments != null) {
        _assignedVariants = cachedExperiments;
        _experimentsLoaded = true;
        _experimentsReadyCompleter!.complete();
        MGMLogger.debug('Restored experiments from cache: $_assignedVariants');
        return;
      }

      // Fetch from server if no valid cache
      await _fetchExperiments();
    } catch (e) {
      MGMLogger.error('Error initializing experiments', e);
      _assignedVariants = {};
      _experimentsLoaded = true;
      if (!_experimentsReadyCompleter!.isCompleted) {
        _experimentsReadyCompleter!.complete();
      }
    }
  }

  /// Restore experiments from cache if valid (same user and within 24h TTL).
  Future<Map<String, String>?> _restoreExperimentsFromCache() async {
    final cachedUserId = await _stateStorage!.getString(_experimentsUserIdKey);
    final fetchedAtStr =
        await _stateStorage!.getString(_experimentsFetchedAtKey);
    final experimentsJson = await _stateStorage!.getString(_experimentsKey);

    // Check if cache exists
    if (cachedUserId == null ||
        fetchedAtStr == null ||
        experimentsJson == null) {
      return null;
    }

    // Check if user matches
    if (cachedUserId != _effectiveUserId) {
      MGMLogger.debug('Experiments cache user mismatch, will refetch');
      return null;
    }

    // Check if cache is within TTL
    final fetchedAt = int.tryParse(fetchedAtStr);
    if (fetchedAt == null) {
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - fetchedAt) > _twentyFourHoursMs) {
      MGMLogger.debug('Experiments cache expired, will refetch');
      return null;
    }

    // Parse cached experiments
    try {
      final decoded = json.decode(experimentsJson) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      MGMLogger.warning('Failed to parse cached experiments: $e');
      return null;
    }
  }

  /// Fetch experiments from server and cache them.
  Future<void> _fetchExperiments() async {
    final userId = _effectiveUserId;
    if (userId == null) {
      MGMLogger.debug('No user ID available, skipping experiments fetch');
      _assignedVariants = {};
      _experimentsLoaded = true;
      if (!_experimentsReadyCompleter!.isCompleted) {
        _experimentsReadyCompleter!.complete();
      }
      return;
    }

    final result = await _networkClient!.fetchExperiments(userId, _config!);

    if (result.success && result.assignedVariants != null) {
      _assignedVariants = result.assignedVariants!;
      await _cacheExperiments(userId, _assignedVariants);
      MGMLogger.debug('Fetched and cached experiments: $_assignedVariants');
    } else {
      MGMLogger.warning('Failed to fetch experiments, using empty variants');
      _assignedVariants = {};
    }

    _experimentsLoaded = true;
    if (!_experimentsReadyCompleter!.isCompleted) {
      _experimentsReadyCompleter!.complete();
    }
  }

  /// Cache experiments to persistent storage.
  Future<void> _cacheExperiments(
    String userId,
    Map<String, String> variants,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _stateStorage!.setString(_experimentsUserIdKey, userId);
    await _stateStorage!.setString(_experimentsFetchedAtKey, now.toString());
    await _stateStorage!.setString(_experimentsKey, jsonEncode(variants));
  }

  /// Clear cached experiments.
  Future<void> _clearExperimentsCache() async {
    await _stateStorage!.setString(_experimentsUserIdKey, null);
    await _stateStorage!.setString(_experimentsFetchedAtKey, null);
    await _stateStorage!.setString(_experimentsKey, null);
  }

  /// Get the variant assigned to the current user for an experiment.
  ///
  /// Returns null if the experiment doesn't exist, the user is not assigned
  /// to a variant, or experiments haven't loaded yet.
  ///
  /// When a variant is returned, a super property `$experiment_{snake_case_name}`
  /// is automatically set with the variant value.
  ///
  /// Example:
  /// ```dart
  /// final variant = MostlyGoodMetrics.getVariant('My Experiment');
  /// if (variant == 'treatment') {
  ///   // Show treatment UI
  /// }
  /// ```
  static String? getVariant(String experimentName) {
    _ensureConfigured();

    final mgm = instance;
    final variant = mgm._assignedVariants[experimentName];

    if (variant != null) {
      // Set super property with snake_case name
      final snakeCaseName = MGMUtils.toSnakeCase(experimentName);
      final propertyKey = '\$experiment_$snakeCaseName';
      mgm._superProperties[propertyKey] = variant;
      // Persist asynchronously - don't await to keep method sync
      mgm._saveSuperProperties();
      MGMLogger.debug(
        'getVariant($experimentName) = $variant, set $propertyKey',
      );
    } else {
      MGMLogger.debug('getVariant($experimentName) = null');
    }

    return variant;
  }

  /// Returns a Future that completes when experiments have been loaded.
  ///
  /// Use this to wait for experiments to be available before accessing
  /// variants, especially if you need to make UI decisions based on
  /// experiment assignment early in the app lifecycle.
  ///
  /// Example:
  /// ```dart
  /// await MostlyGoodMetrics.configure(config);
  /// await MostlyGoodMetrics.ready();
  /// final variant = MostlyGoodMetrics.getVariant('onboarding_flow');
  /// ```
  static Future<void> ready() {
    _ensureConfigured();

    final mgm = instance;
    if (mgm._experimentsLoaded) {
      return Future.value();
    }
    return mgm._experimentsReadyCompleter?.future ?? Future.value();
  }

  /// Check if experiments have been loaded.
  static bool get experimentsLoaded {
    if (!_isConfigured) return false;
    return instance._experimentsLoaded;
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
      WidgetsBinding.instance.removeObserver(_instance!);
    }
    _instance = null;
    _isConfigured = false;
  }

  /// Get the current assigned variants (for testing).
  static Map<String, String> get assignedVariants {
    _ensureConfigured();
    return Map<String, String>.from(instance._assignedVariants);
  }
}
