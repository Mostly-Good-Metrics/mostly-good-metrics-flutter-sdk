import 'dart:async';

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
    test('returns server-assigned variant for known experiment', () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
        'pricing_test': 'control',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'treatment');
      expect(MostlyGoodMetrics.getVariant('pricing_test'), 'control');

      // The initial fetch uses the anonymous ID with no anonymous_id param.
      expect(
        networkClient.experimentsFetchedForUsers,
        [MostlyGoodMetrics.anonymousId],
      );
      expect(networkClient.experimentsFetchedWithAnonymousIds, [null]);
    });

    test('returns null for unknown experiment and never buckets locally',
        () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(MostlyGoodMetrics.getVariant('unknown_experiment'), null);
    });

    test('returns fallback for unknown experiment', () async {
      networkClient.experimentsToReturn = {};

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(
        MostlyGoodMetrics.getVariant('unknown', fallback: 'control'),
        'control',
      );
    });

    test('returns fallback before experiments have loaded', () async {
      networkClient.experimentsToReturn = {'onboarding_flow': 'treatment'};
      networkClient.experimentsFetchGate = Completer<void>();

      await configureSDK();

      // Fetch still in flight - synchronous read serves the fallback
      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), null);
      expect(
        MostlyGoodMetrics.getVariant('onboarding_flow', fallback: 'control'),
        'control',
      );

      networkClient.experimentsFetchGate!.complete();
      expect(await MostlyGoodMetrics.ready(), true);
      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'treatment');
    });

    test('never throws when SDK is not configured', () {
      expect(MostlyGoodMetrics.getVariant('any'), null);
      expect(
        MostlyGoodMetrics.getVariant('any', fallback: 'control'),
        'control',
      );
    });

    test('returns fallback when fetch fails', () async {
      networkClient.experimentsSuccess = false;

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(MostlyGoodMetrics.getVariant('any_experiment'), null);
      expect(
        MostlyGoodMetrics.getVariant('any_experiment', fallback: 'control'),
        'control',
      );
    });

    test('sets super property with experiment prefix when variant accessed',
        () async {
      networkClient.experimentsToReturn = {
        'My Experiment': 'treatment',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      MostlyGoodMetrics.getVariant('My Experiment');

      // Wait a tick for async super property save
      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(superProps[r'$experiment_my__experiment'], 'treatment');
    });

    test('sets snake_case super property for camelCase experiment name',
        () async {
      networkClient.experimentsToReturn = {
        'myExperimentName': 'variant_b',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      MostlyGoodMetrics.getVariant('myExperimentName');

      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(superProps[r'$experiment_my_experiment_name'], 'variant_b');
    });

    test('does not set super property when variant is null', () async {
      networkClient.experimentsToReturn = {};

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      MostlyGoodMetrics.getVariant('nonexistent');

      await Future<void>.delayed(Duration.zero);

      final superProps = MostlyGoodMetrics.getSuperProperties();
      expect(
        superProps.keys.where((k) => k.startsWith(r'$experiment_')).length,
        0,
      );
    });
  });

  group('A/B Testing - exposure tracking', () {
    Future<List<MGMEvent>> exposureEvents() async {
      final events = await eventStorage.fetchEvents(100);
      return events.where((e) => e.name == r'$experiment_exposure').toList();
    }

    test(r'tracks $experiment_exposure once per user/experiment/variant',
        () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      MostlyGoodMetrics.getVariant('onboarding_flow');
      MostlyGoodMetrics.getVariant('onboarding_flow');
      MostlyGoodMetrics.getVariant('onboarding_flow');

      final exposures = await exposureEvents();
      expect(exposures.length, 1);
      expect(exposures[0].properties?[r'$experiment_name'], 'onboarding_flow');
      expect(exposures[0].properties?[r'$variant'], 'treatment');
    });

    test('exposure dedup survives a simulated restart', () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'treatment',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      MostlyGoodMetrics.getVariant('onboarding_flow');
      await Future<void>.delayed(Duration.zero);
      expect((await exposureEvents()).length, 1);

      // Simulated restart: fresh instance and event storage, same
      // persisted state storage
      MostlyGoodMetrics.reset();
      eventStorage = InMemoryEventStorage();
      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'treatment');
      await Future<void>.delayed(Duration.zero);

      expect(
        (await exposureEvents()).length,
        0,
        reason: 'Exposure dedup must persist across restarts',
      );
    });
  });

  group('A/B Testing - ready()', () {
    test('resolves true after experiments load', () async {
      networkClient.experimentsToReturn = {'test': 'variant'};

      await configureSDK();

      expect(await MostlyGoodMetrics.ready(), true);
      expect(MostlyGoodMetrics.experimentsLoaded, true);
    });

    test('resolves immediately if already loaded', () async {
      networkClient.experimentsToReturn = {'test': 'variant'};

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Second call should complete immediately
      expect(await MostlyGoodMetrics.ready(), true);
    });

    test('resolves true even when fetch fails', () async {
      networkClient.experimentsSuccess = false;

      await configureSDK();

      expect(await MostlyGoodMetrics.ready(), true);
      expect(MostlyGoodMetrics.experimentsLoaded, true);
      expect(MostlyGoodMetrics.assignedVariants, isEmpty);
    });

    test('resolves false on timeout when the fetch hangs', () async {
      networkClient.experimentsToReturn = {'test': 'variant'};
      networkClient.experimentsFetchGate = Completer<void>();

      await configureSDK();

      final stopwatch = Stopwatch()..start();
      final loaded = await MostlyGoodMetrics.ready(
        timeout: const Duration(milliseconds: 200),
      );
      stopwatch.stop();

      expect(loaded, false);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'ready() must not hang past its timeout',
      );

      // getVariant stays safe while the fetch hangs
      expect(
        MostlyGoodMetrics.getVariant('test', fallback: 'fallback'),
        'fallback',
      );

      networkClient.experimentsFetchGate!.complete();
    });

    test('resolves false when SDK is not configured', () async {
      expect(
        await MostlyGoodMetrics.ready(
          timeout: const Duration(milliseconds: 100),
        ),
        false,
      );
    });

    test('default timeout is 5 seconds', () {
      expect(
        MostlyGoodMetrics.defaultReadyTimeout,
        const Duration(seconds: 5),
      );
    });
  });

  group('A/B Testing - caching', () {
    test('caches variants in storage', () async {
      networkClient.experimentsToReturn = {
        'cached_experiment': 'cached_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Check that experiments were stored
      final storedExperiments = await stateStorage.getString('experiments');
      expect(storedExperiments, isNotNull);
      expect(storedExperiments, contains('cached_experiment'));
    });

    test('restores variants from cache on reconfigure without refetching',
        () async {
      networkClient.experimentsToReturn = {
        'cached_experiment': 'cached_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Reset and reconfigure with same storage (simulating app restart)
      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsToReturn = {
        'different_experiment': 'should_not_see_this',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Cache served, and the refetch was throttled (recent last fetch)
      expect(
        MostlyGoodMetrics.getVariant('cached_experiment'),
        'cached_variant',
      );
      expect(networkClient.experimentsFetchedForUsers, isEmpty);
    });

    test('cached variants never expire', () async {
      networkClient.experimentsToReturn = {
        'old_experiment': 'old_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Age the cache by 30 days
      final longAgo = DateTime.now()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      await stateStorage.setString('experimentsFetchedAt', longAgo.toString());

      // Reset and reconfigure with a hanging fetch - only the cache can serve
      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsFetchGate = Completer<void>();

      await configureSDK();
      // Let the async cache restore settle (fetch is still hanging)
      await Future<void>.delayed(Duration.zero);

      expect(
        MostlyGoodMetrics.getVariant('old_experiment'),
        'old_variant',
        reason: 'A 30-day-old cache must still be served (no expiry)',
      );

      networkClient.experimentsFetchGate!.complete();
    });

    test('stale cache is served immediately then refreshed in background',
        () async {
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'stale_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Age the cache past the ~1h refetch throttle
      final twoHoursAgo = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await stateStorage.setString(
        'experimentsFetchedAt',
        twoHoursAgo.toString(),
      );

      // Restart with a gated fetch returning fresh variants
      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsFetchGate = Completer<void>();
      networkClient.experimentsToReturn = {
        'onboarding_flow': 'fresh_variant',
      };

      await configureSDK();
      await Future<void>.delayed(Duration.zero);

      // Stale value served while the refetch is in flight
      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'stale_variant');
      expect(networkClient.experimentsFetchedForUsers, isNotEmpty);

      networkClient.experimentsFetchGate!.complete();
      expect(await MostlyGoodMetrics.ready(), true);

      expect(MostlyGoodMetrics.getVariant('onboarding_flow'), 'fresh_variant');
    });
  });

  group('A/B Testing - identify', () {
    test('keeps serving current variants then swaps atomically', () async {
      networkClient.experimentsToReturn = {
        'anon_experiment': 'anon_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), 'anon_variant');

      final anonymousId = MostlyGoodMetrics.anonymousId;

      // Gate the identify refetch so we can observe the in-flight window
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsFetchedWithAnonymousIds.clear();
      networkClient.experimentsFetchGate = Completer<void>();
      networkClient.experimentsToReturn = {
        'user_experiment': 'user_variant',
      };

      await MostlyGoodMetrics.identify('user-123');

      // While the refetch is in flight, old variants keep being served -
      // never cleared to null mid-session
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), 'anon_variant');

      // The refetch is for the new user and links the stored anonymous ID
      expect(networkClient.experimentsFetchedForUsers, ['user-123']);
      expect(networkClient.experimentsFetchedWithAnonymousIds, [anonymousId]);

      networkClient.experimentsFetchGate!.complete();
      await Future<void>.delayed(Duration.zero);

      // Atomic swap once the response arrives
      expect(MostlyGoodMetrics.getVariant('user_experiment'), 'user_variant');
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), null);
    });

    test('background refetch includes anonymous_id while identified', () async {
      networkClient.experimentsToReturn = {'experiment': 'variant'};

      await configureSDK();
      await MostlyGoodMetrics.identify('user-123');
      expect(await MostlyGoodMetrics.ready(), true);
      await Future<void>.delayed(Duration.zero);

      final anonymousId = MostlyGoodMetrics.anonymousId;

      // Age the cache past the ~1h throttle and restart while identified
      final twoHoursAgo = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await stateStorage.setString(
        'experimentsFetchedAt',
        twoHoursAgo.toString(),
      );

      MostlyGoodMetrics.reset();
      networkClient.experimentsFetchedForUsers.clear();
      networkClient.experimentsFetchedWithAnonymousIds.clear();

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      // Every fetch while identified links the stored anonymous ID,
      // not only the identify()-triggered refetch.
      expect(networkClient.experimentsFetchedForUsers, ['user-123']);
      expect(networkClient.experimentsFetchedWithAnonymousIds, [anonymousId]);
    });

    test('does not refetch when identify called with same user', () async {
      networkClient.experimentsToReturn = {
        'experiment': 'variant',
      };

      await configureSDK();
      await MostlyGoodMetrics.identify('user-123');
      expect(await MostlyGoodMetrics.ready(), true);
      await Future<void>.delayed(Duration.zero);

      final fetchCount = networkClient.experimentsFetchedForUsers.length;

      // Identify again with same user
      await MostlyGoodMetrics.identify('user-123');
      await Future<void>.delayed(Duration.zero);

      // Should not have fetched again
      expect(
        networkClient.experimentsFetchedForUsers.length,
        fetchCount,
      );
    });

    test('keeps current variants when the identify refetch fails', () async {
      networkClient.experimentsToReturn = {
        'anon_experiment': 'anon_variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);
      expect(MostlyGoodMetrics.getVariant('anon_experiment'), 'anon_variant');

      networkClient.experimentsSuccess = false;
      await MostlyGoodMetrics.identify('user-123');
      await Future<void>.delayed(Duration.zero);

      expect(
        MostlyGoodMetrics.getVariant('anon_experiment'),
        'anon_variant',
        reason: 'Variants must never be cleared mid-session',
      );
    });

    test('updates the cached user after a successful identify refetch',
        () async {
      networkClient.experimentsToReturn = {
        'experiment': 'variant',
      };

      await configureSDK();
      expect(await MostlyGoodMetrics.ready(), true);

      await MostlyGoodMetrics.identify('new-user');
      await Future<void>.delayed(Duration.zero);

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
      expect(await MostlyGoodMetrics.ready(), true);

      // Access variant to set super property
      MostlyGoodMetrics.getVariant('button_test');
      await Future<void>.delayed(Duration.zero);

      // Track an event
      MostlyGoodMetrics.track('button_clicked');

      final events = await eventStorage.fetchEvents(10);
      final clickEvent = events.firstWhere((e) => e.name == 'button_clicked');
      expect(
        clickEvent.properties?[r'$experiment_button_test'],
        'blue_button',
      );
    });
  });
}
