import 'dart:async';

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
  String? _sessionId;
  bool _isAppInForeground = true;

  // Storage keys
  static const String _userIdKey = 'userId';
  static const String _sessionIdKey = 'sessionId';
  static const String _appVersionKey = 'appVersion';

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
    mgm._eventStorage =
        eventStorage ?? FileEventStorage(maxStoredEvents: config.maxStoredEvents);
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

    MGMLogger.debug('MostlyGoodMetrics SDK configured successfully');
  }

  Future<void> _restoreState() async {
    _userId = await _stateStorage!.getString(_userIdKey);
    MGMLogger.debug('Restored userId: $_userId');
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
        track(r'$app_updated', properties: {
          'previous_version': storedVersion,
          'current_version': currentVersion,
        },);
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

    // Validate properties
    final propsError = MGMUtils.validateProperties(properties);
    if (propsError != null) {
      throw MGMError(
        type: MGMErrorType.invalidProperties,
        message: propsError,
      );
    }

    final event = MGMEvent(
      name: name,
      timestamp: DateTime.now(),
      userId: mgm._userId,
      sessionId: mgm._sessionId,
      platform: MGMUtils.getPlatformName(),
      appVersion: mgm._config!.appVersion,
      osVersion: MGMUtils.getOSVersion(),
      environment: mgm._config!.environment,
      deviceManufacturer: MGMUtils.getDeviceManufacturer(),
      locale: MGMUtils.getLocale(),
      timezone: MGMUtils.getTimezone(),
      properties: properties,
    );

    mgm._eventStorage!.store(event);
    MGMLogger.debug('Tracked event: $name');
  }

  /// Identify the current user.
  ///
  /// The [userId] will be attached to all subsequent events until
  /// [resetIdentity] is called.
  static Future<void> identify(String userId) async {
    _ensureConfigured();

    final mgm = instance;
    mgm._userId = userId;
    await mgm._stateStorage!.setString(_userIdKey, userId);
    MGMLogger.debug('Identified user: $userId');
  }

  /// Reset the current user identity.
  ///
  /// This clears the userId and starts a new session.
  static Future<void> resetIdentity() async {
    _ensureConfigured();

    final mgm = instance;
    mgm._userId = null;
    await mgm._stateStorage!.setString(_userIdKey, null);

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
        userId: _userId,
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
}
