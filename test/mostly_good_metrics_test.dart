import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryEventStorage eventStorage;
  late InMemoryStateStorage stateStorage;
  late MockNetworkClient networkClient;

  setUp(() {
    eventStorage = InMemoryEventStorage();
    stateStorage = InMemoryStateStorage();
    networkClient = MockNetworkClient();
    MostlyGoodMetrics.reset();
  });

  tearDown(() {
    MostlyGoodMetrics.reset();
  });

  Future<void> configureSDK({
    bool trackLifecycleEvents = false,
    String? appVersion,
  }) async {
    await MostlyGoodMetrics.configure(
      MGMConfiguration(
        apiKey: 'test-api-key',
        trackAppLifecycleEvents: trackLifecycleEvents,
        appVersion: appVersion,
      ),
      eventStorage: eventStorage,
      stateStorage: stateStorage,
      networkClient: networkClient,
    );
  }

  group('MostlyGoodMetrics.configure', () {
    test('configures the SDK successfully', () async {
      expect(MostlyGoodMetrics.isConfigured, false);

      await configureSDK();

      expect(MostlyGoodMetrics.isConfigured, true);
    });

    test('generates a session ID on configure', () async {
      await configureSDK();

      expect(MostlyGoodMetrics.sessionId, isNotNull);
      expect(MostlyGoodMetrics.sessionId!.length, 36); // UUID format
    });

    test(r'tracks $app_opened when lifecycle events enabled', () async {
      await configureSDK(trackLifecycleEvents: true);

      final count = await eventStorage.eventCount();
      expect(count, 1);

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].name, r'$app_opened');
    });

    test(r'does not track $app_opened when lifecycle events disabled',
        () async {
      await configureSDK(trackLifecycleEvents: false);

      final count = await eventStorage.eventCount();
      expect(count, 0);
    });

    test('allows reconfiguration', () async {
      await configureSDK();
      final firstSessionId = MostlyGoodMetrics.sessionId;

      await configureSDK();
      final secondSessionId = MostlyGoodMetrics.sessionId;

      expect(firstSessionId, isNot(secondSessionId));
    });
  });

  group('MostlyGoodMetrics.track', () {
    test('throws when not configured', () {
      expect(
        () => MostlyGoodMetrics.track('test_event'),
        throwsA(isA<MGMError>()),
      );
    });

    test('tracks event with name only', () async {
      await configureSDK();

      MostlyGoodMetrics.track('button_clicked');

      final count = await eventStorage.eventCount();
      expect(count, 1);

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].name, 'button_clicked');
    });

    test('tracks event with properties', () async {
      await configureSDK();

      MostlyGoodMetrics.track(
        'purchase',
        properties: {
          'product_id': 'abc123',
          'price': 9.99,
          'currency': 'USD',
        },
      );

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].name, 'purchase');
      expect(events[0].properties!['product_id'], 'abc123');
      expect(events[0].properties!['price'], 9.99);
      expect(events[0].properties!['currency'], 'USD');
    });

    test('includes session ID in event', () async {
      await configureSDK();

      MostlyGoodMetrics.track('test_event');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].sessionId, MostlyGoodMetrics.sessionId);
    });

    test('includes user ID when identified', () async {
      await configureSDK();
      await MostlyGoodMetrics.identify('user-123');

      MostlyGoodMetrics.track('test_event');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].userId, 'user-123');
    });

    test('includes app version when configured', () async {
      await configureSDK(appVersion: '2.0.0');

      MostlyGoodMetrics.track('test_event');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].appVersion, '2.0.0');
    });

    test('throws on invalid event name', () async {
      await configureSDK();

      expect(
        () => MostlyGoodMetrics.track('123_invalid'),
        throwsA(
          isA<MGMError>().having(
            (e) => e.type,
            'type',
            MGMErrorType.invalidEventName,
          ),
        ),
      );
    });

    test('throws on empty event name', () async {
      await configureSDK();

      expect(
        () => MostlyGoodMetrics.track(''),
        throwsA(
          isA<MGMError>().having(
            (e) => e.type,
            'type',
            MGMErrorType.invalidEventName,
          ),
        ),
      );
    });

    test('throws on deeply nested properties', () async {
      await configureSDK();

      expect(
        () => MostlyGoodMetrics.track(
          'test',
          properties: {
            'l1': {
              'l2': {
                'l3': {
                  'l4': 'too deep',
                },
              },
            },
          },
        ),
        throwsA(
          isA<MGMError>().having(
            (e) => e.type,
            'type',
            MGMErrorType.invalidProperties,
          ),
        ),
      );
    });
  });

  group('MostlyGoodMetrics.identify', () {
    test('sets user ID', () async {
      await configureSDK();

      await MostlyGoodMetrics.identify('user-456');

      expect(MostlyGoodMetrics.userId, 'user-456');
    });

    test('persists user ID', () async {
      await configureSDK();
      await MostlyGoodMetrics.identify('user-789');

      final storedUserId = await stateStorage.getString('userId');
      expect(storedUserId, 'user-789');
    });

    test('updates subsequent events with user ID', () async {
      await configureSDK();
      MostlyGoodMetrics.track('before_identify');

      await MostlyGoodMetrics.identify('user-test');
      MostlyGoodMetrics.track('after_identify');

      final events = await eventStorage.fetchEvents(2);
      expect(events[0].userId, null);
      expect(events[1].userId, 'user-test');
    });
  });

  group('MostlyGoodMetrics.resetIdentity', () {
    test('clears user ID', () async {
      await configureSDK();
      await MostlyGoodMetrics.identify('user-to-clear');

      await MostlyGoodMetrics.resetIdentity();

      expect(MostlyGoodMetrics.userId, null);
    });

    test('starts new session on reset', () async {
      await configureSDK();
      final originalSessionId = MostlyGoodMetrics.sessionId;

      await MostlyGoodMetrics.resetIdentity();

      expect(MostlyGoodMetrics.sessionId, isNot(originalSessionId));
    });

    test('clears persisted user ID', () async {
      await configureSDK();
      await MostlyGoodMetrics.identify('user-to-clear');

      await MostlyGoodMetrics.resetIdentity();

      final storedUserId = await stateStorage.getString('userId');
      expect(storedUserId, null);
    });
  });

  group('MostlyGoodMetrics.startNewSession', () {
    test('generates new session ID', () async {
      await configureSDK();
      final originalSessionId = MostlyGoodMetrics.sessionId;

      await MostlyGoodMetrics.startNewSession();

      expect(MostlyGoodMetrics.sessionId, isNot(originalSessionId));
    });

    test('preserves user ID', () async {
      await configureSDK();
      await MostlyGoodMetrics.identify('persistent-user');

      await MostlyGoodMetrics.startNewSession();

      expect(MostlyGoodMetrics.userId, 'persistent-user');
    });
  });

  group('MostlyGoodMetrics.flush', () {
    test('sends events via network client', () async {
      await configureSDK();
      MostlyGoodMetrics.track('event1');
      MostlyGoodMetrics.track('event2');

      await MostlyGoodMetrics.flush();

      expect(networkClient.sentPayloads.length, 1);
      expect(networkClient.sentPayloads[0].events.length, 2);
    });

    test('removes events after successful send', () async {
      await configureSDK();
      MostlyGoodMetrics.track('event1');

      await MostlyGoodMetrics.flush();

      final count = await eventStorage.eventCount();
      expect(count, 0);
    });

    test('keeps events on failure', () async {
      await configureSDK();
      MostlyGoodMetrics.track('event1');

      networkClient.resultToReturn = SendResult.failure;
      await MostlyGoodMetrics.flush();

      final count = await eventStorage.eventCount();
      expect(count, 1);
    });

    test('does nothing when no events', () async {
      await configureSDK();

      await MostlyGoodMetrics.flush();

      expect(networkClient.sentPayloads.length, 0);
    });
  });

  group('MostlyGoodMetrics.getPendingEventCount', () {
    test('returns correct count', () async {
      await configureSDK();

      expect(await MostlyGoodMetrics.getPendingEventCount(), 0);

      MostlyGoodMetrics.track('event1');
      expect(await MostlyGoodMetrics.getPendingEventCount(), 1);

      MostlyGoodMetrics.track('event2');
      expect(await MostlyGoodMetrics.getPendingEventCount(), 2);
    });
  });

  group('MostlyGoodMetrics.clearPendingEvents', () {
    test('clears all events', () async {
      await configureSDK();
      MostlyGoodMetrics.track('event1');
      MostlyGoodMetrics.track('event2');

      await MostlyGoodMetrics.clearPendingEvents();

      expect(await MostlyGoodMetrics.getPendingEventCount(), 0);
    });
  });

  group('Event context', () {
    test('includes platform in event', () async {
      await configureSDK();
      MostlyGoodMetrics.track('test_event');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].platform, isNotEmpty);
    });

    test('includes environment in event', () async {
      await MostlyGoodMetrics.configure(
        const MGMConfiguration(
          apiKey: 'test-key',
          environment: 'staging',
          trackAppLifecycleEvents: false,
        ),
        eventStorage: eventStorage,
        stateStorage: stateStorage,
        networkClient: networkClient,
      );

      MostlyGoodMetrics.track('test_event');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].environment, 'staging');
    });

    test('includes timestamp in event', () async {
      await configureSDK();
      final before = DateTime.now();

      MostlyGoodMetrics.track('test_event');

      final after = DateTime.now();
      final events = await eventStorage.fetchEvents(1);

      expect(
          events[0]
              .timestamp
              .isAfter(before.subtract(const Duration(seconds: 1))),
          true);
      expect(
          events[0].timestamp.isBefore(after.add(const Duration(seconds: 1))),
          true);
    });
  });
}
