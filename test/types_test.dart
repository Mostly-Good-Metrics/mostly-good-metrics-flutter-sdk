import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';

void main() {
  group('MGMConfiguration', () {
    test('creates with required parameters', () {
      const config = MGMConfiguration(apiKey: 'test-api-key');

      expect(config.apiKey, 'test-api-key');
      expect(config.baseUrl, 'https://ingest.mostlygoodmetrics.com');
      expect(config.environment, 'production');
      expect(config.maxBatchSize, 100);
      expect(config.flushInterval, 30);
      expect(config.maxStoredEvents, 10000);
      expect(config.enableDebugLogging, false);
      expect(config.trackAppLifecycleEvents, true);
    });

    test('creates with all parameters', () {
      const config = MGMConfiguration(
        apiKey: 'test-api-key',
        baseUrl: 'https://custom.api.com',
        environment: 'staging',
        appVersion: '2.0.0',
        maxBatchSize: 50,
        flushInterval: 60,
        maxStoredEvents: 5000,
        enableDebugLogging: true,
        trackAppLifecycleEvents: false,
      );

      expect(config.apiKey, 'test-api-key');
      expect(config.baseUrl, 'https://custom.api.com');
      expect(config.environment, 'staging');
      expect(config.appVersion, '2.0.0');
      expect(config.maxBatchSize, 50);
      expect(config.flushInterval, 60);
      expect(config.maxStoredEvents, 5000);
      expect(config.enableDebugLogging, true);
      expect(config.trackAppLifecycleEvents, false);
    });

    test('copyWith creates new instance with updated values', () {
      const original = MGMConfiguration(apiKey: 'test-key');
      final copied = original.copyWith(
        environment: 'development',
        appVersion: '1.0.0',
      );

      expect(copied.apiKey, 'test-key');
      expect(copied.environment, 'development');
      expect(copied.appVersion, '1.0.0');
      // Original should be unchanged
      expect(original.environment, 'production');
      expect(original.appVersion, null);
    });
  });

  group('MGMEvent', () {
    test('creates event with all fields', () {
      final timestamp = DateTime.now();
      final event = MGMEvent(
        name: 'test_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: timestamp,
        userId: 'user-123',
        sessionId: 'session-456',
        platform: 'ios',
        appVersion: '1.0.0',
        osVersion: '17.0',
        environment: 'production',
        properties: {'key': 'value'},
      );

      expect(event.name, 'test_event');
      expect(event.clientEventId, '550e8400-e29b-41d4-a716-446655440000');
      expect(event.timestamp, timestamp);
      expect(event.userId, 'user-123');
      expect(event.sessionId, 'session-456');
      expect(event.platform, 'ios');
      expect(event.appVersion, '1.0.0');
      expect(event.osVersion, '17.0');
      expect(event.environment, 'production');
      expect(event.properties, {'key': 'value'});
    });

    test('toJson serializes correctly', () {
      final timestamp = DateTime.utc(2024, 1, 15, 12, 30, 45);
      final event = MGMEvent(
        name: 'test_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: timestamp,
        userId: 'user-123',
        sessionId: 'session-456',
        platform: 'android',
        appVersion: '2.0.0',
        osVersion: '14',
        environment: 'staging',
        properties: {'count': 42},
      );

      final json = event.toJson();

      expect(json['name'], 'test_event');
      expect(json['client_event_id'], '550e8400-e29b-41d4-a716-446655440000');
      expect(json['timestamp'], '2024-01-15T12:30:45.000Z');
      expect(json['userId'], 'user-123');
      expect(json['sessionId'], 'session-456');
      expect(json['platform'], 'android');
      expect(json['appVersion'], '2.0.0');
      expect(json['osVersion'], '14');
      expect(json['environment'], 'staging');
      expect(json['properties'], {'count': 42});
    });

    test('toJson excludes null fields', () {
      final timestamp = DateTime.utc(2024, 1, 15);
      final event = MGMEvent(
        name: 'minimal_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: timestamp,
        platform: 'web',
        environment: 'production',
      );

      final json = event.toJson();

      expect(json.containsKey('client_event_id'), true);
      expect(json.containsKey('userId'), false);
      expect(json.containsKey('sessionId'), false);
      expect(json.containsKey('appVersion'), false);
      expect(json.containsKey('osVersion'), false);
      expect(json.containsKey('properties'), false);
    });

    test('fromJson deserializes correctly', () {
      final json = {
        'name': 'deserialized_event',
        'client_event_id': '550e8400-e29b-41d4-a716-446655440000',
        'timestamp': '2024-01-15T10:00:00.000Z',
        'userId': 'user-789',
        'sessionId': 'session-abc',
        'platform': 'macos',
        'appVersion': '3.0.0',
        'osVersion': '14.0',
        'environment': 'development',
        'properties': {
          'nested': {'key': 'value'},
        },
      };

      final event = MGMEvent.fromJson(json);

      expect(event.name, 'deserialized_event');
      expect(event.clientEventId, '550e8400-e29b-41d4-a716-446655440000');
      expect(event.timestamp, DateTime.utc(2024, 1, 15, 10, 0, 0));
      expect(event.userId, 'user-789');
      expect(event.sessionId, 'session-abc');
      expect(event.platform, 'macos');
      expect(event.appVersion, '3.0.0');
      expect(event.osVersion, '14.0');
      expect(event.environment, 'development');
      expect(event.properties, {
        'nested': {'key': 'value'},
      });
    });

    test('roundtrip serialization works', () {
      final original = MGMEvent(
        name: 'roundtrip_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: DateTime.utc(2024, 6, 1, 15, 30),
        userId: 'user-test',
        sessionId: 'session-test',
        platform: 'linux',
        appVersion: '1.2.3',
        osVersion: 'Ubuntu 22.04',
        environment: 'production',
        properties: {'a': 1, 'b': 'two', 'c': true},
      );

      final json = original.toJson();
      final deserialized = MGMEvent.fromJson(json);

      expect(deserialized.name, original.name);
      expect(deserialized.clientEventId, original.clientEventId);
      expect(deserialized.timestamp, original.timestamp);
      expect(deserialized.userId, original.userId);
      expect(deserialized.sessionId, original.sessionId);
      expect(deserialized.platform, original.platform);
      expect(deserialized.appVersion, original.appVersion);
      expect(deserialized.osVersion, original.osVersion);
      expect(deserialized.environment, original.environment);
      expect(deserialized.properties, original.properties);
    });

    test('creates event with new device properties', () {
      final timestamp = DateTime.now();
      final event = MGMEvent(
        name: 'test_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: timestamp,
        platform: 'ios',
        environment: 'production',
        appVersion: '1.2.3',
        appBuildNumber: '42',
        deviceManufacturer: 'Apple',
        locale: 'en_US',
        timezone: 'America/New_York',
      );

      expect(event.appVersion, '1.2.3');
      expect(event.appBuildNumber, '42');
      expect(event.deviceManufacturer, 'Apple');
      expect(event.locale, 'en_US');
      expect(event.timezone, 'America/New_York');
    });

    test('toJson includes new device properties', () {
      final timestamp = DateTime.utc(2024, 1, 15, 12, 30, 45);
      final event = MGMEvent(
        name: 'test_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: timestamp,
        platform: 'android',
        environment: 'production',
        appVersion: '1.2.3',
        appBuildNumber: '42',
        deviceManufacturer: 'Samsung',
        locale: 'fr_FR',
        timezone: 'Europe/Paris',
      );

      final json = event.toJson();

      expect(json['appVersion'], '1.2.3');
      expect(json['appBuildNumber'], '42');
      expect(json['deviceManufacturer'], 'Samsung');
      expect(json['locale'], 'fr_FR');
      expect(json['timezone'], 'Europe/Paris');
    });

    test('fromJson deserializes new device properties', () {
      final json = {
        'name': 'deserialized_event',
        'client_event_id': '550e8400-e29b-41d4-a716-446655440000',
        'timestamp': '2024-01-15T10:00:00.000Z',
        'platform': 'android',
        'environment': 'production',
        'appVersion': '2.0.0',
        'appBuildNumber': '123',
        'deviceManufacturer': 'Google',
        'locale': 'de_DE',
        'timezone': 'Europe/Berlin',
      };

      final event = MGMEvent.fromJson(json);

      expect(event.appVersion, '2.0.0');
      expect(event.appBuildNumber, '123');
      expect(event.deviceManufacturer, 'Google');
      expect(event.locale, 'de_DE');
      expect(event.timezone, 'Europe/Berlin');
    });

    test('roundtrip serialization preserves new device properties', () {
      final original = MGMEvent(
        name: 'roundtrip_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: DateTime.utc(2024, 6, 1, 15, 30),
        platform: 'ios',
        environment: 'production',
        appVersion: '1.2.3',
        appBuildNumber: '42',
        deviceManufacturer: 'Apple',
        locale: 'en_US',
        timezone: 'America/New_York',
      );

      final json = original.toJson();
      final deserialized = MGMEvent.fromJson(json);

      expect(deserialized.appVersion, original.appVersion);
      expect(deserialized.appBuildNumber, original.appBuildNumber);
      expect(deserialized.deviceManufacturer, original.deviceManufacturer);
      expect(deserialized.locale, original.locale);
      expect(deserialized.timezone, original.timezone);
    });

    test('clientEventId serializes as client_event_id in JSON', () {
      final event = MGMEvent(
        name: 'test_event',
        clientEventId: '550e8400-e29b-41d4-a716-446655440000',
        timestamp: DateTime.utc(2024, 1, 1),
        platform: 'ios',
        environment: 'production',
      );

      final json = event.toJson();

      expect(json['client_event_id'], '550e8400-e29b-41d4-a716-446655440000');
      expect(json.containsKey('clientEventId'), false);
    });
  });

  group('EventsPayload', () {
    test('toJson serializes events and context', () {
      final timestamp = DateTime.utc(2024, 1, 1);
      final events = [
        MGMEvent(
          name: 'event1',
          clientEventId: '550e8400-e29b-41d4-a716-446655440001',
          timestamp: timestamp,
          platform: 'ios',
          environment: 'production',
        ),
        MGMEvent(
          name: 'event2',
          clientEventId: '550e8400-e29b-41d4-a716-446655440002',
          timestamp: timestamp,
          platform: 'ios',
          environment: 'production',
        ),
      ];

      const context = EventContext(
        platform: 'ios',
        appVersion: '1.0.0',
        userId: 'user-123',
        sessionId: 'session-456',
        environment: 'production',
      );

      final payload = EventsPayload(events: events, context: context);
      final json = payload.toJson();

      expect(json['events'], isA<List>());
      expect((json['events'] as List).length, 2);
      expect(json['context']['platform'], 'ios');
      expect(json['context']['appVersion'], '1.0.0');
    });
  });

  group('EventContext', () {
    test('creates with new device properties', () {
      const context = EventContext(
        platform: 'ios',
        appVersion: '1.2.3',
        appBuildNumber: '42',
        environment: 'production',
        deviceManufacturer: 'Apple',
        locale: 'en_US',
        timezone: 'America/New_York',
      );

      expect(context.appVersion, '1.2.3');
      expect(context.appBuildNumber, '42');
      expect(context.deviceManufacturer, 'Apple');
      expect(context.locale, 'en_US');
      expect(context.timezone, 'America/New_York');
    });

    test('toJson includes new device properties', () {
      const context = EventContext(
        platform: 'android',
        appVersion: '2.0.0',
        appBuildNumber: '100',
        environment: 'staging',
        deviceManufacturer: 'Samsung',
        locale: 'fr_FR',
        timezone: 'Europe/Paris',
      );

      final json = context.toJson();

      expect(json['appVersion'], '2.0.0');
      expect(json['appBuildNumber'], '100');
      expect(json['deviceManufacturer'], 'Samsung');
      expect(json['locale'], 'fr_FR');
      expect(json['timezone'], 'Europe/Paris');
    });

    test('toJson excludes null device properties', () {
      const context = EventContext(
        platform: 'ios',
        environment: 'production',
      );

      final json = context.toJson();

      expect(json.containsKey('appBuildNumber'), false);
      expect(json.containsKey('deviceManufacturer'), false);
      expect(json.containsKey('locale'), false);
      expect(json.containsKey('timezone'), false);
    });
  });

  group('MGMError', () {
    test('creates error with type and message', () {
      const error = MGMError(
        type: MGMErrorType.notConfigured,
        message: 'SDK not configured',
      );

      expect(error.type, MGMErrorType.notConfigured);
      expect(error.message, 'SDK not configured');
      expect(error.underlyingError, null);
    });

    test('creates error with underlying error', () {
      final underlying = Exception('Network failed');
      final error = MGMError(
        type: MGMErrorType.networkError,
        message: 'Failed to send events',
        underlyingError: underlying,
      );

      expect(error.type, MGMErrorType.networkError);
      expect(error.underlyingError, underlying);
    });

    test('toString formats correctly', () {
      const error = MGMError(
        type: MGMErrorType.invalidEventName,
        message: 'Event name cannot be empty',
      );

      expect(
        error.toString(),
        'MGMError(invalidEventName): Event name cannot be empty',
      );
    });
  });
}
