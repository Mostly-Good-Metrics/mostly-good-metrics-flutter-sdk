import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'bucketing.dart';
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
  bool _isOptedOut = false;

  // Storage keys
  static const String _userIdKey = 'userId';
  static const String _anonymousIdKey = 'anonymousId';
  static const String _sessionIdKey = 'sessionId';
  static const String _optedOutKey = 'optedOut';
  static const String _appVersionKey = 'appVersion';
  static const String _superPropertiesKey = 'superProperties';
  static const String _identifyHashKey = 'identifyHash';
  static const String _identifyTimestampKey = 'identifyTimestamp';
  static const String _experimentsKey = 'experiments';
  static const String _experimentsUserIdKey = 'experimentsUserId';
  static const String _experimentsFetchedAtKey = 'experimentsFetchedAt';
  static const String _experimentExposuresKey = 'experimentExposures';
  static const String _localExperimentConfigsKey = 'localExperimentConfigs';
  static const String _localExperimentConfigsFetchedAtKey =
      'localExperimentConfigsFetchedAt';
  // Sticky local assignments (experiment UUID -> variant). Cleared by the
  // forget-me flow (resetIdentity(clearAnonymousId: true)) so a new
  // identity is re-bucketed instead of reusing the old assignments.
  static const String _localExperimentAssignmentsKey =
      'localExperimentAssignments';

  // 24 hours in milliseconds
  static const int _twentyFourHoursMs = 24 * 60 * 60 * 1000;

  // Background refetches of experiment variants are throttled to ~1 hour.
  // The cached variants themselves never expire (stale-while-revalidate).
  static const int _experimentsRefetchIntervalMs = 60 * 60 * 1000;

  /// Default timeout for [ready].
  static const Duration defaultReadyTimeout = Duration(seconds: 5);

  /// The effective user ID to use in events (identified user or anonymous).
  String? get _effectiveUserId => _userId ?? _anonymousId;

  // In-memory cache for super properties
  Map<String, dynamic> _superProperties = {};

  // A/B testing state. In server mode variants are assigned by the server;
  // in local mode they are bucketed on device from experiment configs.
  Map<String, String> _assignedVariants = {};
  Completer<void>? _experimentsReadyCompleter;
  bool _experimentsLoaded = false;

  // Local enrollment state: experiment configs keyed by name, and sticky
  // assignments keyed by experiment UUID.
  Map<String, MGMExperimentConfig> _localExperimentsByName = {};
  Map<String, String> _localAssignments = {};

  bool get _isLocalExperimentMode =>
      _config?.experimentMode == MGMExperimentMode.local;

  // Exposure dedup ("userId|experiment|variant"), persisted to storage.
  Set<String> _trackedExposures = {};

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

    // Restore opt-out state. A persisted choice always wins over the
    // configured default.
    final optedOutStr = await _stateStorage!.getString(_optedOutKey);
    _isOptedOut = optedOutStr != null
        ? optedOutStr == 'true'
        : _config!.optedOutByDefault;
    MGMLogger.debug('Restored optedOut: $_isOptedOut');

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

    // Restore exposure dedup state
    _trackedExposures = {};
    final exposuresJson =
        await _stateStorage!.getString(_experimentExposuresKey);
    if (exposuresJson != null) {
      try {
        _trackedExposures = (json.decode(exposuresJson) as List<dynamic>)
            .map((e) => e.toString())
            .toSet();
      } catch (e) {
        MGMLogger.warning('Failed to restore experiment exposures: $e');
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
  /// Does nothing while the user is opted out (see [optOut]).
  ///
  /// Throws [MGMError] if the SDK is not configured or if validation fails.
  static void track(String name, {Map<String, dynamic>? properties}) {
    _ensureConfigured();

    final mgm = instance;

    if (mgm._isOptedOut) {
      MGMLogger.debug('Opted out, dropping event: $name');
      return;
    }

    // Validate event name
    final nameError = MGMUtils.validateEventName(name);
    if (nameError != null) {
      throw MGMError(
        type: MGMErrorType.invalidEventName,
        message: nameError,
      );
    }

    // Merge properties: super properties < event properties < system properties
    // Event properties override super properties; system properties (e.g. $sdk)
    // are always added last so every event carries them, matching the other
    // MGM SDKs (JS, Swift, etc.) for property-based filtering/breakdowns.
    final mergedProperties = <String, dynamic>{
      ...mgm._superProperties,
      if (properties != null) ...properties,
      r'$sdk': sdkName,
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
      deviceManufacturer: mgm._config!.collectDeviceProperties
          ? MGMUtils.getDeviceManufacturer()
          : null,
      locale:
          mgm._config!.collectDeviceProperties ? MGMUtils.getLocale() : null,
      timezone:
          mgm._config!.collectDeviceProperties ? MGMUtils.getTimezone() : null,
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
  /// If the user ID changes, experiment variants are refetched for the new
  /// user (linking the stored anonymous ID). The currently served variants
  /// stay in place until the response arrives, then are swapped atomically —
  /// they are never cleared mid-session.
  ///
  /// Does nothing while the user is opted out (see [optOut]).
  static Future<void> identify(String userId, {UserProfile? profile}) async {
    _ensureConfigured();

    final mgm = instance;

    if (mgm._isOptedOut) {
      MGMLogger.debug('Opted out, ignoring identify: $userId');
      return;
    }

    final previousUserId = mgm._userId;
    mgm._userId = userId;
    await mgm._stateStorage!.setString(_userIdKey, userId);
    MGMLogger.debug('Identified user: $userId');

    // If the user changed, refetch variants for the new user in the
    // background, including the stored anonymous ID so the server can
    // migrate prior anonymous assignments. In local mode assignments are
    // sticky per experiment — the SDK never re-buckets after identify().
    if (previousUserId != userId && !mgm._isLocalExperimentMode) {
      unawaited(mgm._fetchExperiments());
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

      // Send stored anon id (when distinct) so the backend can merge pre-identify events.
      final anonymousId = _anonymousId;
      if (anonymousId != null &&
          anonymousId.isNotEmpty &&
          anonymousId != userId) {
        properties[r'$anonymous_id'] = anonymousId;
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
  ///
  /// When [clearAnonymousId] is true, this is a full "forget me": the
  /// persisted anonymous ID is rotated, all pending (unsent) events are
  /// purged, all super properties are cleared, and sticky local experiment
  /// assignments are cleared (so the new identity is re-bucketed fresh) —
  /// nothing tracked after the reset can be linked to the previous user.
  static Future<void> resetIdentity({bool clearAnonymousId = false}) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._userId = null;
    await mgm._stateStorage!.setString(_userIdKey, null);
    await mgm._clearIdentifyState();

    if (clearAnonymousId) {
      // Rotate the anonymous ID
      mgm._anonymousId = MGMUtils.generateAnonymousId();
      await mgm._stateStorage!.setString(_anonymousIdKey, mgm._anonymousId);

      // Purge pending events queued under the previous identity
      await mgm._eventStorage!.clear();

      // Clear super properties
      mgm._superProperties.clear();
      await mgm._stateStorage!.setString(_superPropertiesKey, null);

      // Clear sticky local experiment assignments so the rotated identity
      // is re-bucketed fresh instead of reusing the old assignments
      mgm._localAssignments = {};
      await mgm._stateStorage!.setString(_localExperimentAssignmentsKey, null);
    }

    // Start new session
    mgm._sessionId = MGMUtils.generateUUID();
    await mgm._stateStorage!.setString(_sessionIdKey, mgm._sessionId);

    MGMLogger.debug('Identity reset (clearAnonymousId=$clearAnonymousId)');
  }

  /// Rotate the anonymous ID.
  ///
  /// Generates a new persisted anonymous ID. Events tracked afterwards
  /// (while not identified) can no longer be linked to the previous
  /// anonymous ID.
  static Future<void> resetAnonymousId() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._anonymousId = MGMUtils.generateAnonymousId();
    await mgm._stateStorage!.setString(_anonymousIdKey, mgm._anonymousId);
    MGMLogger.debug('Rotated anonymousId: ${mgm._anonymousId}');
  }

  // Privacy / Opt-Out

  /// Opt the user out of all tracking.
  ///
  /// Takes effect immediately: [track], [identify], and [flush] become
  /// no-ops, and all pending (unsent) events are purged. The choice is
  /// persisted and survives app restarts, until [optIn] is called.
  static Future<void> optOut() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._isOptedOut = true;
    await mgm._stateStorage!.setString(_optedOutKey, 'true');

    // Purge any events queued before the opt-out
    await mgm._eventStorage!.clear();

    MGMLogger.debug('Opted out of tracking');
  }

  /// Opt the user back in to tracking.
  ///
  /// Re-enables [track], [identify], and [flush]. The choice is persisted
  /// and survives app restarts.
  static Future<void> optIn() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._isOptedOut = false;
    await mgm._stateStorage!.setString(_optedOutKey, 'false');
    MGMLogger.debug('Opted in to tracking');
  }

  /// Whether the user is currently opted out of tracking.
  static bool get isOptedOut {
    _ensureConfigured();
    return instance._isOptedOut;
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

  /// Initialize experiments: serve the persisted per-user cache immediately
  /// (stale-while-revalidate — the cache never expires), then refresh from
  /// the server in the background, throttled to roughly once per hour.
  /// Never blocks configure().
  Future<void> _initializeExperiments() async {
    _experimentsReadyCompleter = Completer<void>();
    _experimentsLoaded = false;

    if (_isLocalExperimentMode) {
      await _initializeLocalExperiments();
      return;
    }

    try {
      // Serve the cached variants immediately, however old they are.
      final cachedExperiments = await _restoreExperimentsFromCache();
      if (cachedExperiments != null) {
        _assignedVariants = cachedExperiments;
        MGMLogger.debug('Restored experiments from cache: $_assignedVariants');
      }

      // Background refetch, throttled to ~1h since the last fetch.
      if (await _shouldRefetchExperiments()) {
        await _fetchExperiments();
      } else {
        MGMLogger.debug(
          'Skipping experiments refetch (throttled), serving cached variants',
        );
        _experimentsLoaded = true;
        _completeExperimentsReady();
      }
    } catch (e) {
      MGMLogger.error('Error initializing experiments', e);
      _experimentsLoaded = true;
      _completeExperimentsReady();
    }
  }

  void _completeExperimentsReady() {
    if (!(_experimentsReadyCompleter?.isCompleted ?? true)) {
      _experimentsReadyCompleter!.complete();
    }
  }

  /// Restore experiment variants from the per-user cache.
  ///
  /// The cache has no expiry — it is only skipped when it belongs to a
  /// different user.
  Future<Map<String, String>?> _restoreExperimentsFromCache() async {
    final cachedUserId = await _stateStorage!.getString(_experimentsUserIdKey);
    final experimentsJson = await _stateStorage!.getString(_experimentsKey);

    // Check if cache exists
    if (cachedUserId == null || experimentsJson == null) {
      return null;
    }

    // Check if user matches
    if (cachedUserId != _effectiveUserId) {
      MGMLogger.debug('Experiments cache user mismatch, will refetch');
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

  /// Whether a background refetch is due (more than ~1h since the last
  /// fetch for the current user).
  Future<bool> _shouldRefetchExperiments() async {
    final cachedUserId = await _stateStorage!.getString(_experimentsUserIdKey);
    if (cachedUserId != _effectiveUserId) return true;

    final fetchedAtStr =
        await _stateStorage!.getString(_experimentsFetchedAtKey);
    final fetchedAt = fetchedAtStr != null ? int.tryParse(fetchedAtStr) : null;
    if (fetchedAt == null) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - fetchedAt) > _experimentsRefetchIntervalMs;
  }

  /// Fetch server-assigned variants and swap them in atomically on success.
  ///
  /// On failure the currently served variants are kept untouched — they are
  /// never cleared mid-session.
  Future<void> _fetchExperiments() async {
    try {
      final userId = _effectiveUserId;
      if (userId == null) {
        MGMLogger.debug('No user ID available, skipping experiments fetch');
        return;
      }

      // Link the stored anonymous ID on every fetch while identified (the
      // effective user ID differs from the stored anonymous ID), so the
      // server can migrate prior anonymous assignments. Mirrors the JS SDK.
      final anonymousId = userId != _anonymousId ? _anonymousId : null;

      final result = await _networkClient!.fetchExperiments(
        userId,
        _config!,
        anonymousId: anonymousId,
      );

      if (result.success && result.assignedVariants != null) {
        // Atomic swap: a single map assignment, never a clear-then-set.
        _assignedVariants = result.assignedVariants!;
        await _cacheExperiments(userId, _assignedVariants);
        MGMLogger.debug('Fetched and cached experiments: $_assignedVariants');
      } else {
        MGMLogger.warning(
          'Failed to fetch experiments, keeping current variants',
        );
      }
    } catch (e) {
      MGMLogger.error('Error fetching experiments', e);
    } finally {
      _experimentsLoaded = true;
      _completeExperimentsReady();
    }
  }

  /// Cache experiments to persistent storage (per user, no expiry).
  Future<void> _cacheExperiments(
    String userId,
    Map<String, String> variants,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _stateStorage!.setString(_experimentsUserIdKey, userId);
    await _stateStorage!.setString(_experimentsFetchedAtKey, now.toString());
    await _stateStorage!.setString(_experimentsKey, jsonEncode(variants));
  }

  // Local experiment enrollment

  /// Initialize experiments for [MGMExperimentMode.local]: restore sticky
  /// assignments, then load experiment configs — inline from the
  /// configuration when provided (zero network), otherwise cached configs
  /// are served immediately and refreshed from the server in the
  /// background, throttled like server-mode assignments. Never blocks
  /// configure().
  Future<void> _initializeLocalExperiments() async {
    try {
      await _restoreLocalAssignments();

      final inlineExperiments = _config!.localExperiments;
      if (inlineExperiments != null) {
        _setLocalExperimentConfigs(inlineExperiments);
        MGMLogger.debug(
          'Using ${inlineExperiments.length} inline local experiments',
        );
        _experimentsLoaded = true;
        _completeExperimentsReady();
        return;
      }

      // Serve cached configs immediately, however old they are.
      final cachedConfigs = await _restoreLocalConfigsFromCache();
      if (cachedConfigs != null) {
        _setLocalExperimentConfigs(cachedConfigs);
        MGMLogger.debug(
          'Restored ${cachedConfigs.length} local experiment configs '
          'from cache',
        );
      }

      // Background refetch, throttled to ~1h since the last fetch. Never
      // fetches while opted out — local mode makes zero network requests in
      // that state; bucketing keeps working from inline/cached configs.
      if (_isOptedOut) {
        MGMLogger.debug('Opted out, skipping local experiment configs fetch');
        _experimentsLoaded = true;
        _completeExperimentsReady();
      } else if (await _shouldRefetchLocalConfigs()) {
        await _fetchLocalExperimentConfigs();
      } else {
        MGMLogger.debug(
          'Skipping local experiment configs refetch (throttled), '
          'serving cached configs',
        );
        _experimentsLoaded = true;
        _completeExperimentsReady();
      }
    } catch (e) {
      MGMLogger.error('Error initializing local experiments', e);
      _experimentsLoaded = true;
      _completeExperimentsReady();
    }
  }

  void _setLocalExperimentConfigs(List<MGMExperimentConfig> configs) {
    _localExperimentsByName = {
      for (final config in configs) config.name: config,
    };
  }

  /// Restore sticky local assignments (experiment UUID -> variant).
  Future<void> _restoreLocalAssignments() async {
    _localAssignments = {};
    final assignmentsJson =
        await _stateStorage!.getString(_localExperimentAssignmentsKey);
    if (assignmentsJson == null) return;
    try {
      final decoded = json.decode(assignmentsJson) as Map<String, dynamic>;
      _localAssignments =
          decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      MGMLogger.warning('Failed to restore local experiment assignments: $e');
    }
  }

  Future<void> _saveLocalAssignments() async {
    await _stateStorage!.setString(
      _localExperimentAssignmentsKey,
      jsonEncode(_localAssignments),
    );
  }

  /// Restore local experiment configs from the cache (no expiry).
  Future<List<MGMExperimentConfig>?> _restoreLocalConfigsFromCache() async {
    final configsJson =
        await _stateStorage!.getString(_localExperimentConfigsKey);
    if (configsJson == null) return null;
    try {
      return (json.decode(configsJson) as List<dynamic>)
          .map((e) => MGMExperimentConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      MGMLogger.warning('Failed to parse cached local experiment configs: $e');
      return null;
    }
  }

  /// Whether a background refetch of local experiment configs is due
  /// (more than ~1h since the last fetch).
  Future<bool> _shouldRefetchLocalConfigs() async {
    final fetchedAtStr =
        await _stateStorage!.getString(_localExperimentConfigsFetchedAtKey);
    final fetchedAt = fetchedAtStr != null ? int.tryParse(fetchedAtStr) : null;
    if (fetchedAt == null) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - fetchedAt) > _experimentsRefetchIntervalMs;
  }

  /// Fetch experiment configs for local enrollment and swap them in
  /// atomically on success. On failure the currently served configs are
  /// kept untouched.
  Future<void> _fetchLocalExperimentConfigs() async {
    try {
      final result = await _networkClient!.fetchExperimentConfigs(_config!);

      if (result.success && result.experiments != null) {
        _setLocalExperimentConfigs(result.experiments!);
        final now = DateTime.now().millisecondsSinceEpoch;
        await _stateStorage!.setString(
          _localExperimentConfigsKey,
          jsonEncode(result.experiments!.map((e) => e.toJson()).toList()),
        );
        await _stateStorage!.setString(
          _localExperimentConfigsFetchedAtKey,
          now.toString(),
        );
        MGMLogger.debug(
          'Fetched and cached ${result.experiments!.length} local '
          'experiment configs',
        );
      } else {
        MGMLogger.warning(
          'Failed to fetch local experiment configs, keeping current configs',
        );
      }
    } catch (e) {
      MGMLogger.error('Error fetching local experiment configs', e);
    } finally {
      _experimentsLoaded = true;
      _completeExperimentsReady();
    }
  }

  /// Resolve a variant in local mode: reuse the sticky persisted assignment
  /// for the experiment UUID when present, otherwise bucket on device and
  /// persist the result.
  String? _getLocalVariant(String experimentName, String? fallback) {
    final experiment = _localExperimentsByName[experimentName];
    if (experiment == null) {
      MGMLogger.debug('getVariant($experimentName) = fallback ($fallback)');
      return fallback;
    }

    var variant = _localAssignments[experiment.id];
    if (variant == null) {
      final userId = _effectiveUserId;
      if (userId == null) {
        MGMLogger.debug('getVariant($experimentName) = fallback ($fallback)');
        return fallback;
      }

      variant = MGMBucketing.variantFor(
        experiment.id,
        userId,
        experiment.variants,
      );
      if (variant == null) {
        MGMLogger.debug('getVariant($experimentName) = fallback ($fallback)');
        return fallback;
      }

      // Sticky: persist the assignment so the user keeps this variant even
      // after identify() changes the effective user ID.
      _localAssignments[experiment.id] = variant;
      // Persist asynchronously - don't await to keep getVariant sync
      unawaited(_saveLocalAssignments());
      MGMLogger.debug(
        'Bucketed locally: experiment "$experimentName" -> "$variant"',
      );
    }

    _recordExposure(experimentName, variant);
    MGMLogger.debug('getVariant($experimentName) = $variant');
    return variant;
  }

  /// Get the assigned variant for an experiment.
  ///
  /// In [MGMExperimentMode.server] (default) variants are assigned by the
  /// server. In [MGMExperimentMode.local] variants are bucketed on device
  /// by deterministically hashing the experiment ID and effective user ID;
  /// the first assignment per experiment is persisted and reused (sticky).
  ///
  /// This method is synchronous and non-blocking: it reads from the
  /// in-memory cache (hydrated from persistent storage at configure) and
  /// returns [fallback] (default null) when the experiment is unknown,
  /// assignments haven't loaded yet, or the SDK is not configured.
  /// It never throws.
  ///
  /// Reading a variant also:
  /// - sets the super property `$experiment_{snake_case(name)}` so the
  ///   variant is attached to all subsequent events
  /// - tracks a `$experiment_exposure` event once per
  ///   (user, experiment, variant), persisted across restarts
  ///
  /// Example:
  /// ```dart
  /// final variant = MostlyGoodMetrics.getVariant(
  ///   'My Experiment',
  ///   fallback: 'control',
  /// );
  /// if (variant == 'treatment') {
  ///   // Show treatment UI
  /// }
  /// ```
  static String? getVariant(String experimentName, {String? fallback}) {
    try {
      if (!_isConfigured) {
        MGMLogger.warning('getVariant called before configure()');
        return fallback;
      }

      final mgm = instance;

      if (mgm._isLocalExperimentMode) {
        return mgm._getLocalVariant(experimentName, fallback);
      }

      final variant = mgm._assignedVariants[experimentName];

      if (variant == null) {
        MGMLogger.debug('getVariant($experimentName) = fallback ($fallback)');
        return fallback;
      }

      mgm._recordExposure(experimentName, variant);
      MGMLogger.debug('getVariant($experimentName) = $variant');
      return variant;
    } catch (e) {
      MGMLogger.warning('getVariant($experimentName) failed: $e');
      return fallback;
    }
  }

  /// Set the experiment super property and track the `$experiment_exposure`
  /// event, deduplicated per (user, experiment, variant). The dedup state is
  /// persisted so it survives app restarts.
  ///
  /// Records nothing while the user is opted out — no super property, no
  /// exposure event, and no dedup state — so the exposure fires on the
  /// first variant read after [optIn].
  void _recordExposure(String experimentName, String variant) {
    if (_isOptedOut) {
      MGMLogger.debug(
        'Opted out, not recording exposure for "$experimentName"',
      );
      return;
    }

    final snakeCaseName = MGMUtils.toSnakeCase(experimentName);
    final propertyKey = '\$experiment_$snakeCaseName';
    if (_superProperties[propertyKey] != variant) {
      _superProperties[propertyKey] = variant;
      // Persist asynchronously - don't await to keep getVariant sync
      unawaited(_saveSuperProperties());
    }

    final exposureKey = '$_effectiveUserId|$experimentName|$variant';
    if (_trackedExposures.contains(exposureKey)) return;
    _trackedExposures.add(exposureKey);
    unawaited(
      _stateStorage!.setString(
        _experimentExposuresKey,
        jsonEncode(_trackedExposures.toList()),
      ),
    );

    track(
      r'$experiment_exposure',
      properties: {
        r'$experiment_name': experimentName,
        r'$variant': variant,
      },
    );
    MGMLogger.debug(
      'Tracked exposure for experiment "$experimentName" variant "$variant"',
    );
  }

  /// Returns a Future that completes when the initial experiments load
  /// attempt has finished (success or failure), or when [timeout] elapses —
  /// whichever comes first. No path hangs.
  ///
  /// Resolves to true if the load attempt completed, false if the timeout
  /// elapsed first (or the SDK is not configured).
  ///
  /// Example:
  /// ```dart
  /// await MostlyGoodMetrics.configure(config);
  /// final loaded = await MostlyGoodMetrics.ready(
  ///   timeout: Duration(seconds: 2),
  /// );
  /// final variant = MostlyGoodMetrics.getVariant('onboarding_flow');
  /// ```
  static Future<bool> ready({Duration timeout = defaultReadyTimeout}) async {
    if (!_isConfigured) {
      MGMLogger.warning('ready() called before configure()');
      return false;
    }

    final mgm = instance;
    if (mgm._experimentsLoaded) {
      return true;
    }

    final future = mgm._experimentsReadyCompleter?.future;
    if (future == null) {
      return true;
    }

    try {
      await future.timeout(timeout);
      return true;
    } on TimeoutException {
      MGMLogger.debug('ready() timed out after $timeout');
      return false;
    }
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
    if (_isOptedOut) {
      MGMLogger.debug('Opted out, skipping flush');
      return;
    }

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
        deviceManufacturer: _config!.collectDeviceProperties
            ? MGMUtils.getDeviceManufacturer()
            : null,
        locale: _config!.collectDeviceProperties ? MGMUtils.getLocale() : null,
        timezone:
            _config!.collectDeviceProperties ? MGMUtils.getTimezone() : null,
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
            track(r'$app_opened');
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

  /// Get the sticky local assignments, keyed by experiment UUID
  /// (for testing).
  static Map<String, String> get localExperimentAssignments {
    _ensureConfigured();
    return Map<String, String>.from(instance._localAssignments);
  }
}
