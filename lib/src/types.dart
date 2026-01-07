/// Configuration options for the MostlyGoodMetrics SDK.
class MGMConfiguration {
  /// The API key for authenticating with MostlyGoodMetrics.
  final String apiKey;

  /// The base URL for the MostlyGoodMetrics API.
  final String baseUrl;

  /// The environment name (e.g., 'production', 'staging', 'development').
  final String environment;

  /// The version of your application.
  final String? appVersion;

  /// Maximum number of events to send in a single batch.
  final int maxBatchSize;

  /// Interval in seconds between automatic event flushes.
  final int flushInterval;

  /// Maximum number of events to store locally.
  final int maxStoredEvents;

  /// Whether to enable debug logging.
  final bool enableDebugLogging;

  /// Whether to automatically track app lifecycle events.
  final bool trackAppLifecycleEvents;

  /// Creates a new configuration for MostlyGoodMetrics.
  const MGMConfiguration({
    required this.apiKey,
    this.baseUrl = 'https://ingest.mostlygoodmetrics.com',
    this.environment = 'production',
    this.appVersion,
    this.maxBatchSize = 100,
    this.flushInterval = 30,
    this.maxStoredEvents = 10000,
    this.enableDebugLogging = false,
    this.trackAppLifecycleEvents = true,
  })  : assert(maxBatchSize >= 1 && maxBatchSize <= 1000),
        assert(flushInterval >= 1),
        assert(maxStoredEvents >= 100);

  /// Creates a copy of this configuration with the given fields replaced.
  MGMConfiguration copyWith({
    String? apiKey,
    String? baseUrl,
    String? environment,
    String? appVersion,
    int? maxBatchSize,
    int? flushInterval,
    int? maxStoredEvents,
    bool? enableDebugLogging,
    bool? trackAppLifecycleEvents,
  }) {
    return MGMConfiguration(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      environment: environment ?? this.environment,
      appVersion: appVersion ?? this.appVersion,
      maxBatchSize: maxBatchSize ?? this.maxBatchSize,
      flushInterval: flushInterval ?? this.flushInterval,
      maxStoredEvents: maxStoredEvents ?? this.maxStoredEvents,
      enableDebugLogging: enableDebugLogging ?? this.enableDebugLogging,
      trackAppLifecycleEvents:
          trackAppLifecycleEvents ?? this.trackAppLifecycleEvents,
    );
  }
}

/// Represents an analytics event to be tracked.
class MGMEvent {
  /// The name of the event.
  final String name;

  /// Unique client-generated ID for deduplication.
  final String clientEventId;

  /// The timestamp when the event occurred.
  final DateTime timestamp;

  /// Optional user identifier.
  final String? userId;

  /// Session identifier.
  final String? sessionId;

  /// The platform where the event occurred.
  final String platform;

  /// The app version.
  final String? appVersion;

  /// The app build number (separate from version).
  final String? appBuildNumber;

  /// The OS version.
  final String? osVersion;

  /// The environment (production, staging, etc.).
  final String environment;

  /// The device manufacturer (e.g., "Apple", "Samsung").
  final String? deviceManufacturer;

  /// The user's locale (e.g., "en_US").
  final String? locale;

  /// The user's timezone (e.g., "America/New_York").
  final String? timezone;

  /// Custom properties attached to the event.
  final Map<String, dynamic>? properties;

  /// Creates a new event.
  const MGMEvent({
    required this.name,
    required this.clientEventId,
    required this.timestamp,
    this.userId,
    this.sessionId,
    required this.platform,
    this.appVersion,
    this.appBuildNumber,
    this.osVersion,
    required this.environment,
    this.deviceManufacturer,
    this.locale,
    this.timezone,
    this.properties,
  });

  /// Creates an event from a JSON map.
  factory MGMEvent.fromJson(Map<String, dynamic> json) {
    return MGMEvent(
      name: json['name'] as String,
      clientEventId: json['client_event_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      userId: json['user_id'] as String?,
      sessionId: json['session_id'] as String?,
      platform: json['platform'] as String,
      appVersion: json['app_version'] as String?,
      appBuildNumber: json['app_build_number'] as String?,
      osVersion: json['os_version'] as String?,
      environment: json['environment'] as String,
      deviceManufacturer: json['device_manufacturer'] as String?,
      locale: json['locale'] as String?,
      timezone: json['timezone'] as String?,
      properties: json['properties'] as Map<String, dynamic>?,
    );
  }

  /// Converts this event to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'client_event_id': clientEventId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      if (userId != null) 'user_id': userId,
      if (sessionId != null) 'session_id': sessionId,
      'platform': platform,
      if (appVersion != null) 'app_version': appVersion,
      if (appBuildNumber != null) 'app_build_number': appBuildNumber,
      if (osVersion != null) 'os_version': osVersion,
      'environment': environment,
      if (deviceManufacturer != null) 'device_manufacturer': deviceManufacturer,
      if (locale != null) 'locale': locale,
      if (timezone != null) 'timezone': timezone,
      if (properties != null) 'properties': properties,
    };
  }
}

/// Represents the payload sent to the API.
class EventsPayload {
  /// The list of events to send.
  final List<MGMEvent> events;

  /// Context information shared across events.
  final EventContext context;

  /// Creates a new events payload.
  const EventsPayload({
    required this.events,
    required this.context,
  });

  /// Converts this payload to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'events': events.map((e) => e.toJson()).toList(),
      'context': context.toJson(),
    };
  }
}

/// Context information shared across events in a batch.
class EventContext {
  /// The platform where events occurred.
  final String platform;

  /// The app version.
  final String? appVersion;

  /// The app build number.
  final String? appBuildNumber;

  /// The OS version.
  final String? osVersion;

  /// The user identifier.
  final String? userId;

  /// The session identifier.
  final String? sessionId;

  /// The environment.
  final String environment;

  /// The device manufacturer.
  final String? deviceManufacturer;

  /// The user's locale.
  final String? locale;

  /// The user's timezone.
  final String? timezone;

  /// Creates a new event context.
  const EventContext({
    required this.platform,
    this.appVersion,
    this.appBuildNumber,
    this.osVersion,
    this.userId,
    this.sessionId,
    required this.environment,
    this.deviceManufacturer,
    this.locale,
    this.timezone,
  });

  /// Converts this context to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'platform': platform,
      if (appVersion != null) 'app_version': appVersion,
      if (appBuildNumber != null) 'app_build_number': appBuildNumber,
      if (osVersion != null) 'os_version': osVersion,
      if (userId != null) 'user_id': userId,
      if (sessionId != null) 'session_id': sessionId,
      'environment': environment,
      if (deviceManufacturer != null) 'device_manufacturer': deviceManufacturer,
      if (locale != null) 'locale': locale,
      if (timezone != null) 'timezone': timezone,
    };
  }
}

/// Error types that can occur in the SDK.
enum MGMErrorType {
  /// The SDK has not been configured.
  notConfigured,

  /// Invalid event name.
  invalidEventName,

  /// Invalid properties.
  invalidProperties,

  /// Network error.
  networkError,

  /// Storage error.
  storageError,

  /// Rate limited by the API.
  rateLimited,

  /// Unknown error.
  unknown,
}

/// Represents an error from the SDK.
class MGMError implements Exception {
  /// The type of error.
  final MGMErrorType type;

  /// A human-readable error message.
  final String message;

  /// The underlying error, if any.
  final Object? underlyingError;

  /// Creates a new SDK error.
  const MGMError({
    required this.type,
    required this.message,
    this.underlyingError,
  });

  @override
  String toString() => 'MGMError(${type.name}): $message';
}

/// Result of sending events to the API.
enum SendResult {
  /// Events were sent successfully.
  success,

  /// Events were partially sent.
  partialSuccess,

  /// Failed to send events.
  failure,

  /// Rate limited - should retry later.
  rateLimited,
}

/// User profile data for the identify() call.
class UserProfile {
  /// The user's email address.
  final String? email;

  /// The user's display name.
  final String? name;

  /// Creates a new user profile.
  const UserProfile({
    this.email,
    this.name,
  });
}
