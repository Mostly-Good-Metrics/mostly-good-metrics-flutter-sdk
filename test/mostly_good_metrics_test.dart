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

  group('A/B Testing - getVariant', () {
    test('returns correct variant for known experiment', () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
        'pricing_test': 'control',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'treatment');
      expect(MostlyGoodMetrics.getVariant('pricing_test'), 'control');
    });

    test('returns null for unknown experiment', () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.getVariant('unknown_experiment'), null);
    });

    test('returns null when experiments not loaded', () async {
      networkClient.experimentsSuccess = false;

      await configureSDK();
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.getVariant('any_experiment'), null);
    });

    test('sets super property with experiment prefix when variant accessed',
        () async {
      networkClient.experimentsToReturn = {
        'My Experiment': 'treatment',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      MostlyGoodMetrics.getVariant('My Experiment');

      // Wait a tick for async super property save
      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(superProps[r'$experiment_my_experiment'], 'treatment');
    });

    test('sets snake_case super property for camelCase experiment name',
        () async {
      networkClient.experimentsToReturn = {
        'myExperimentName': 'variant_b',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      MostlyGoodMetrics.getVariant('myExperimentName');

      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(superProps[r'$experiment_my_experiment_name'], 'variant_b');
    });

    test('does not set super property when variant is null', () async {
      networkClient.experimentsToReturn = {};

      await configureSDK();
      await MostlyGoodMetrics.ready();

      MostlyGoodMetrics.getVariant('nonexistent');

      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(
        superProps.keys.where((k) => k.startsWith(r'$experiment_')).length,
        0,
      );
    });
  });

  group('A/B Testing - ready()', () {
    test('completes after experiments load', () async {
      networkClient.experimentsToReturn = {'test': 'variant'};

      await configureSDK();

      // ready() should complete
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.experimentsLoaded, true);
    });

    test('completes immediately if already loaded', () async {
      networkClient.experimentsToReturn = {'test': 'variant'};

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Second call should complete immediately
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.experimentsLoaded, true);
    });

    test('completes even when fetch fails', () async {
      networkClient.experimentsSuccess = false;

      await configureSDK();
      await MostlyGoodMetrics.ready();

      expect(MostlyGoodMetrics.experimentsLoaded, true);
      expect(MostlyGoodMetrics.assignedVariants, isEmpty);
    });
  });

  group('A/B Testing - caching', () {
    test('caches variants in storage', () async {
      networkClient.experimentsToReturn = {
        'cached_experiment': 'cached_variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Check that experiments were stored
      final storedExperiments = await stateStorage.getString('experiments');
      expect(storedExperiments, isNotNull);
      expect(storedExperiments, contains('cached_experiment'));
    });

    test('restores variants from cache on reconfigure', () async {
      networkClient.experimentsToReturn = {
        'cached_experiment': 'cached_variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Reset and reconfigure with same storage
      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsToReturn = {
        'different_experiment': 'should_not_see_this',
      };

      // Reconfigure with same storage (simulating app restart)
      await MostlyGoodMetrics.configure(
        const MGMConfiguration(
          apiKey: 'test-api-key',
          trackAppLifecycleEvents: false,
        ),
        eventStorage: eventStorage,
        stateStorage: stateStorage,
        networkClient: networkClient,
      );
      await MostlyGoodMetrics.ready();

      // Should have used cache (same anonymous ID) instead of fetching
      // The variant should be from cache
      expect(
        MostlyGoodMetrics.getVariant('cached_experiment'),
        'cached_variant',
      );
    });

    test('refetches experiments when cache expires', () async {
      networkClient.experimentsToReturn = {
        'old_experiment': 'old_variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Manually expire the cache by setting old timestamp
      final longAgo = DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch;
      await stateStorage.setString('experimentsFetchedAt', longAgo.toString());

      // Reset and reconfigure
      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsToReturn = {
        'new_experiment': 'new_variant',
      };

      await MostlyGoodMetrics.configure(
        const MGMConfiguration(
          apiKey: 'test-api-key',
          trackAppLifecycleEvents: false,
        ),
        eventStorage: eventStorage,
        stateStorage: stateStorage,
        networkClient: networkClient,
      );
      await MostlyGoodMetrics.ready();

      // Should have fetched new experiments since cache expired
      expect(networkClient.experimentsFetchedForUsers, isNotEmpty);
      expect(MostlyGoodMetrics.getVariant('new_experiment'), 'new_variant');
    });
  });

  group('A/B Testing - identify cache invalidation', () {
    test('invalidates cache and refetches when user changes', () async {
      networkClient.experimentsToReturn = {
        'anon_experiment': 'anon_variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Verify initial experiments
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), 'anon_variant');

      // Now identify as a different user
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsToReturn = {
        'user_experiment': 'user_variant',
      };

      await MostlyGoodMetrics.identify('user-123');
      await MostlyGoodMetrics.ready();

      // Should have fetched new experiments for the new user
      expect(networkClient.experimentsFetchedForUsers, contains('user-123'));
      expect(MostlyGoodMetrics.getVariant('user_experiment'), 'user_variant');
      // Old experiment should no longer be available
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), null);
    });

    test('does not refetch when identify called with same user', () async {
      networkClient.experimentsToReturn = {
        'experiment': 'variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.identify('user-123');
      await MostlyGoodMetrics.ready();

      final fetchCount = networkClient.experimentsFetchedForUsers.length;

      // Identify again with same user
      await MostlyGoodMetrics.identify('user-123');

      // Should not have fetched again
      expect(
        networkClient.experimentsFetchedForUsers.length,
        fetchCount,
      );
    });

    test('clears experiment cache when user changes', () async {
      networkClient.experimentsToReturn = {
        'experiment': 'variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Verify cache exists
      expect(await stateStorage.getString('experiments'), isNotNull);

      // Identify as new user
      await MostlyGoodMetrics.identify('new-user');

      // After identify and refetch, the cached userId should be the new user
      await MostlyGoodMetrics.ready();
      final newCachedUserId = await stateStorage.getString('experimentsUserId');
      expect(newCachedUserId, 'new-user');
    });
  });

  group('A/B Testing - super properties in events', () {
    test('includes experiment super property in tracked events', () async {
      networkClient.experimentsToReturn = {
        'button_test': 'blue_button',
      };

      await configureSDK();
      await MostlyGoodMetrics.ready();

      // Access variant to set super property
      MostlyGoodMetrics.getVariant('button_test');
      await Future<void>.delayed(Duration.zero);

      // Track an event
      MostlyGoodMetrics.track('button_clicked');

      final events = await eventStorage.fetchEvents(1);
      expect(
        events[0].properties?[r'$experiment_button_test'],
        'blue_button',
      );
    });
  });
}
