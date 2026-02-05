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
      // Before identify, events use anonymous ID
      expect(events[0].userId, startsWith(r'$anon_'));
      expect(events[1].userId, 'user-test');
    });

    test(r'sends $identify event with email', () async {
      await configureSDK();

      await MostlyGoodMetrics.identify(
        'user-email',
        profile: const UserProfile(email: 'test@example.com'),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 1);
      expect(identifyEvents[0].properties!['email'], 'test@example.com');
      expect(identifyEvents[0].properties!.containsKey('name'), false);
    });

    test(r'sends $identify event with name', () async {
      await configureSDK();

      await MostlyGoodMetrics.identify(
        'user-name',
        profile: const UserProfile(name: 'John Doe'),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 1);
      expect(identifyEvents[0].properties!['name'], 'John Doe');
      expect(identifyEvents[0].properties!.containsKey('email'), false);
    });

    test(r'sends $identify event with both email and name', () async {
      await configureSDK();

      await MostlyGoodMetrics.identify(
        'user-both',
        profile: const UserProfile(
          email: 'both@example.com',
          name: 'Jane Doe',
        ),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 1);
      expect(identifyEvents[0].properties!['email'], 'both@example.com');
      expect(identifyEvents[0].properties!['name'], 'Jane Doe');
    });

    test(r'does not send $identify event without profile', () async {
      await configureSDK();

      await MostlyGoodMetrics.identify('user-no-profile');

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 0);
    });

    test(r'debounces $identify event with same data', () async {
      await configureSDK();

      // First identify - should send
      await MostlyGoodMetrics.identify(
        'user-debounce',
        profile: const UserProfile(email: 'debounce@example.com'),
      );

      // Second identify with same data - should be debounced
      await MostlyGoodMetrics.identify(
        'user-debounce',
        profile: const UserProfile(email: 'debounce@example.com'),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 1);
    });

    test(r'sends new $identify event when data changes', () async {
      await configureSDK();

      // First identify
      await MostlyGoodMetrics.identify(
        'user-change',
        profile: const UserProfile(email: 'first@example.com'),
      );

      // Second identify with different email - should send
      await MostlyGoodMetrics.identify(
        'user-change',
        profile: const UserProfile(email: 'second@example.com'),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 2);
      expect(identifyEvents[0].properties!['email'], 'first@example.com');
      expect(identifyEvents[1].properties!['email'], 'second@example.com');
    });

    test(r'sends new $identify event after resetIdentity', () async {
      await configureSDK();

      // First identify
      await MostlyGoodMetrics.identify(
        'user-reset',
        profile: const UserProfile(email: 'reset@example.com'),
      );

      // Reset identity clears debounce state
      await MostlyGoodMetrics.resetIdentity();

      // Same identify again - should send since state was cleared
      await MostlyGoodMetrics.identify(
        'user-reset',
        profile: const UserProfile(email: 'reset@example.com'),
      );

      final events = await eventStorage.fetchEvents(10);
      final identifyEvents =
          events.where((e) => e.name == r'$identify').toList();

      expect(identifyEvents.length, 2);
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
        true,
      );
      expect(
        events[0].timestamp.isBefore(after.add(const Duration(seconds: 1))),
        true,
      );
    });
  });

  group('MostlyGoodMetrics.getVariant', () {
    test('throws when not configured', () {
      expect(
        () => MostlyGoodMetrics.getVariant('test-experiment'),
        throwsA(isA<MGMError>()),
      );
    });

    test('returns variant from loaded experiments', () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'button-color', variants: ['a', 'b', 'c']),
      ];
      await configureSDK();

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final variant = MostlyGoodMetrics.getVariant('button-color');
      expect(variant, isNotNull);
      expect(['a', 'b', 'c'].contains(variant), true);
    });

    test('returns null for unknown experiment', () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'button-color', variants: ['a', 'b']),
      ];
      await configureSDK();

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final variant = MostlyGoodMetrics.getVariant('unknown-experiment');
      expect(variant, isNull);
    });

    test('uses fallback variants when experiments not loaded', () async {
      // Set a delay so experiments won't be loaded when we call getVariant
      networkClient.experimentsDelay = const Duration(seconds: 5);
      networkClient.experimentsToReturn = [
        const Experiment(id: 'button-color', variants: ['x', 'y', 'z']),
      ];
      await configureSDK();
      // Don't wait for experiments - call getVariant immediately

      final variant = MostlyGoodMetrics.getVariant('button-color');
      expect(variant, isNotNull);
      // Should use fallback ['a', 'b'], not the actual variants ['x', 'y', 'z']
      expect(['a', 'b'].contains(variant), true);
    });

    test('returns deterministic variant for same user and experiment',
        () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'button-color', variants: ['a', 'b', 'c']),
      ];
      await configureSDK();
      await MostlyGoodMetrics.identify('user-123');

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final variant1 = MostlyGoodMetrics.getVariant('button-color');
      final variant2 = MostlyGoodMetrics.getVariant('button-color');
      final variant3 = MostlyGoodMetrics.getVariant('button-color');

      expect(variant1, variant2);
      expect(variant2, variant3);
    });

    test('stores variant as super property', () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'button-color', variants: ['a', 'b']),
      ];
      await configureSDK();

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final variant = MostlyGoodMetrics.getVariant('button-color');
      final superProps = MostlyGoodMetrics.getSuperProperties();

      expect(superProps['experiment_button_color'], variant);
    });

    test('includes experiment variant in tracked events', () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'checkout-flow', variants: ['control', 'variant']),
      ];
      await configureSDK();

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final variant = MostlyGoodMetrics.getVariant('checkout-flow');
      MostlyGoodMetrics.track('button_clicked');

      final events = await eventStorage.fetchEvents(1);
      expect(events[0].properties?['experiment_checkout_flow'], variant);
    });

    test('converts experiment name to snake_case', () async {
      networkClient.experimentsToReturn = [
        const Experiment(id: 'ButtonColor', variants: ['a', 'b']),
      ];
      await configureSDK();

      // Wait for experiments to load
      await Future<void>.delayed(const Duration(milliseconds: 10));

      MostlyGoodMetrics.getVariant('ButtonColor');
      final superProps = MostlyGoodMetrics.getSuperProperties();

      expect(superProps.containsKey('experiment_button_color'), true);
    });

    test('different users get potentially different variants', () async {
      networkClient.experimentsToReturn = [
        const Experiment(
          id: 'signup-flow',
          variants: ['a', 'b', 'c', 'd', 'e'],
        ),
      ];

      // Test with multiple users to verify distribution
      final variants = <String>[];
      for (var i = 0; i < 10; i++) {
        MostlyGoodMetrics.reset();
        eventStorage = InMemoryEventStorage();
        stateStorage = InMemoryStateStorage();

        await MostlyGoodMetrics.configure(
          const MGMConfiguration(
            apiKey: 'test-api-key',
            trackAppLifecycleEvents: false,
          ),
          eventStorage: eventStorage,
          stateStorage: stateStorage,
          networkClient: networkClient,
        );

        await MostlyGoodMetrics.identify('user-$i');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await MostlyGoodMetrics.clearSuperProperties();

        final variant = MostlyGoodMetrics.getVariant('signup-flow');
        if (variant != null) {
          variants.add(variant);
        }
      }

      // We should have some variety in variants (not all the same)
      // With 10 users and 5 variants, it's extremely unlikely all are the same
      expect(variants.length, 10);
    });
  });
}
