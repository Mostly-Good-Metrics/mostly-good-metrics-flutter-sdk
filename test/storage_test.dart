import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemoryEventStorage', () {
    late InMemoryEventStorage storage;

    setUp(() {
      storage = InMemoryEventStorage();
    });

    int eventCounter = 0;
    MGMEvent createTestEvent(String name) {
      eventCounter++;
      return MGMEvent(
        name: name,
        clientEventId: '550e8400-e29b-41d4-a716-44665544000$eventCounter',
        timestamp: DateTime.now(),
        platform: 'test',
        environment: 'test',
      );
    }

    test('starts with zero events', () async {
      expect(await storage.eventCount(), 0);
    });

    test('stores events', () async {
      await storage.store(createTestEvent('event1'));
      expect(await storage.eventCount(), 1);

      await storage.store(createTestEvent('event2'));
      expect(await storage.eventCount(), 2);
    });

    test('fetches events in order', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));
      await storage.store(createTestEvent('event3'));

      final events = await storage.fetchEvents(3);
      expect(events.length, 3);
      expect(events[0].name, 'event1');
      expect(events[1].name, 'event2');
      expect(events[2].name, 'event3');
    });

    test('fetches events with limit', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));
      await storage.store(createTestEvent('event3'));

      final events = await storage.fetchEvents(2);
      expect(events.length, 2);
      expect(events[0].name, 'event1');
      expect(events[1].name, 'event2');
    });

    test('removes events from front', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));
      await storage.store(createTestEvent('event3'));

      await storage.removeEvents(2);

      expect(await storage.eventCount(), 1);
      final events = await storage.fetchEvents(1);
      expect(events[0].name, 'event3');
    });

    test('clears all events', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));

      await storage.clear();

      expect(await storage.eventCount(), 0);
    });

    test('respects max stored events', () async {
      final limitedStorage = InMemoryEventStorage(maxStoredEvents: 3);

      await limitedStorage.store(createTestEvent('event1'));
      await limitedStorage.store(createTestEvent('event2'));
      await limitedStorage.store(createTestEvent('event3'));
      await limitedStorage.store(createTestEvent('event4'));
      await limitedStorage.store(createTestEvent('event5'));

      expect(await limitedStorage.eventCount(), 3);

      final events = await limitedStorage.fetchEvents(3);
      expect(events[0].name, 'event3');
      expect(events[1].name, 'event4');
      expect(events[2].name, 'event5');
    });

    test('handles fetch with limit larger than event count', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));

      final events = await storage.fetchEvents(100);
      expect(events.length, 2);
    });

    test('handles remove with count larger than event count', () async {
      await storage.store(createTestEvent('event1'));
      await storage.store(createTestEvent('event2'));

      await storage.removeEvents(100);
      expect(await storage.eventCount(), 0);
    });

    test('handles fetch with zero limit', () async {
      await storage.store(createTestEvent('event1'));

      final events = await storage.fetchEvents(0);
      expect(events.length, 0);
    });

    test('handles remove with zero count', () async {
      await storage.store(createTestEvent('event1'));

      await storage.removeEvents(0);
      expect(await storage.eventCount(), 1);
    });

    test('does not remove unsent events after FIFO trimming', () async {
      final limitedStorage = InMemoryEventStorage(maxStoredEvents: 3);
      await limitedStorage.store(createTestEvent('event1'));
      await limitedStorage.store(createTestEvent('event2'));
      await limitedStorage.store(createTestEvent('event3'));

      final sentEvents = await limitedStorage.fetchEvents(2);
      await limitedStorage.store(createTestEvent('event4'));
      await limitedStorage.removeEventsByClientEventId(sentEvents);

      expect(
        (await limitedStorage.fetchEvents(3)).map((event) => event.name),
        ['event3', 'event4'],
      );
    });

    test('removes only the supplied ID-less legacy events', () async {
      final sentLegacyEvent = MGMEvent(
        name: 'sent_legacy',
        clientEventId: '',
        timestamp: DateTime.utc(2025, 12, 9),
        platform: 'test',
        environment: 'test',
      );
      final unsentLegacyEvent = MGMEvent(
        name: 'unsent_legacy',
        clientEventId: '',
        timestamp: DateTime.utc(2025, 12, 9),
        platform: 'test',
        environment: 'test',
      );
      await storage.store(sentLegacyEvent);
      await storage.store(unsentLegacyEvent);

      await storage.removeEventsByClientEventId([sentLegacyEvent]);

      expect(
        (await storage.fetchEvents(2)).map((event) => event.name),
        ['unsent_legacy'],
      );
    });
  });

  group('InMemoryStateStorage', () {
    late InMemoryStateStorage storage;

    setUp(() {
      storage = InMemoryStateStorage();
    });

    test('returns null for non-existent key', () async {
      expect(await storage.getString('nonexistent'), null);
    });

    test('stores and retrieves string values', () async {
      await storage.setString('key', 'value');
      expect(await storage.getString('key'), 'value');
    });

    test('overwrites existing values', () async {
      await storage.setString('key', 'value1');
      await storage.setString('key', 'value2');
      expect(await storage.getString('key'), 'value2');
    });

    test('removes values when set to null', () async {
      await storage.setString('key', 'value');
      await storage.setString('key', null);
      expect(await storage.getString('key'), null);
    });

    test('handles multiple keys independently', () async {
      await storage.setString('key1', 'value1');
      await storage.setString('key2', 'value2');

      expect(await storage.getString('key1'), 'value1');
      expect(await storage.getString('key2'), 'value2');
    });
  });

  group('FileEventStorage', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory documentsDirectory;

    setUp(() async {
      MostlyGoodMetrics.reset();
      documentsDirectory = await Directory.systemTemp.createTemp(
        'mgm-storage-test-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return documentsDirectory.path;
        }
        return null;
      });
    });

    tearDown(() async {
      MostlyGoodMetrics.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      await documentsDirectory.delete(recursive: true);
    });

    MGMEvent createFileEvent(int index) => MGMEvent(
          name: 'event_$index',
          clientEventId:
              '550e8400-e29b-41d4-a716-${index.toString().padLeft(12, '0')}',
          timestamp: DateTime.utc(2026, 9, 25, 12, 34, 56, index),
          platform: 'test',
          environment: 'test',
          properties: {'index': index},
        );

    test('serializes concurrent stores without losing events', () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);

      final stores = [
        for (var index = 0; index < 100; index++)
          storage.store(createFileEvent(index)),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final file = File('${documentsDirectory.path}/mgm_events.json');
      expect(await file.exists(), false);

      await Future.wait(stores);

      final stored = await storage.fetchEvents(100);
      expect(stored.map((event) => event.name), [
        for (var index = 0; index < 100; index++) 'event_$index',
      ]);

      final persisted = json.decode(await file.readAsString()) as List<dynamic>;
      expect(persisted, hasLength(100));
      expect(
        persisted.map((event) => (event as Map<String, dynamic>)['name']),
        [for (var index = 0; index < 100; index++) 'event_$index'],
      );
      expect(
        await File('${documentsDirectory.path}/mgm_events.json.tmp').exists(),
        false,
      );
    });

    test('preserves the existing JSON array format', () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      await storage.store(createFileEvent(1));

      final file = File('${documentsDirectory.path}/mgm_events.json');
      final persisted = json.decode(await file.readAsString()) as List<dynamic>;

      expect(persisted.single, createFileEvent(1).toJson());
    });

    test('preserves JSON format across serialization chunks', () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      await Future.wait([
        for (var index = 0; index < 2501; index++)
          storage.store(createFileEvent(index)),
      ]);

      final file = File('${documentsDirectory.path}/mgm_events.json');
      final persisted = json.decode(await file.readAsString()) as List<dynamic>;

      expect(persisted, hasLength(2501));
      expect((persisted.first as Map<String, dynamic>)['name'], 'event_0');
      expect((persisted.last as Map<String, dynamic>)['name'], 'event_2500');
    });

    test('serves live events while a coalesced write is pending', () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      await storage.store(createFileEvent(1));

      final pendingStore = storage.store(createFileEvent(2));

      expect(await storage.eventCount(), 2);
      expect(
        (await storage.fetchEvents(2)).map((event) => event.name),
        ['event_1', 'event_2'],
      );
      await pendingStore;
    });

    test('keeps persisting across the two-event timer boundary', () async {
      final file = File('${documentsDirectory.path}/mgm_events.json');
      var eventIndex = 100;

      for (final gap in [24, 26, 28, 30]) {
        if (await file.exists()) await file.delete();
        final storage = FileEventStorage(maxStoredEvents: 10000);

        final first = storage.store(createFileEvent(eventIndex++));
        await Future<void>.delayed(Duration(milliseconds: gap));
        final second = storage.store(createFileEvent(eventIndex++));
        await Future.wait([first, second]).timeout(const Duration(seconds: 2));

        // Let any trailing timer fire before proving the next mutation can
        // still reach disk and complete.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await storage
            .store(createFileEvent(eventIndex++))
            .timeout(const Duration(seconds: 2));

        final persisted = json.decode(await file.readAsString()) as List;
        expect(persisted, hasLength(3), reason: 'gap=${gap}ms');
      }
    });

    test('persists during sustained tracking instead of waiting for quiet',
        () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      final file = File('${documentsDirectory.path}/mgm_events.json');
      final stores = <Future<void>>[];
      final producerDone = Completer<void>();
      var index = 0;

      final producer =
          Timer.periodic(const Duration(milliseconds: 10), (timer) {
        stores.add(storage.store(createFileEvent(1000 + index)));
        index++;
        if (index == 100) {
          timer.cancel();
          producerDone.complete();
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(producer.isActive, true);
      expect(await file.exists(), true);
      final midstream = json.decode(await file.readAsString()) as List;
      expect(midstream, isNotEmpty);
      expect(midstream.length, lessThan(100));

      await producerDone.future;
      await Future.wait(stores).timeout(const Duration(seconds: 3));
      final persisted = json.decode(await file.readAsString()) as List;
      expect(persisted, hasLength(100));
    });

    test(
        'backs off failed writes without unhandled errors and recovers while dirty',
        () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      final blockedTarget =
          Directory('${documentsDirectory.path}/mgm_events.json');
      await blockedTarget.create();
      var persistenceAttempts = 0;
      final watcher = documentsDirectory.watch().listen((event) {
        if (event.path.endsWith('mgm_events.json.tmp') &&
            event.type & FileSystemEvent.create != 0) {
          persistenceAttempts++;
        }
      });
      final unhandledErrors = <Object>[];
      final persistedFile = File(blockedTarget.path);
      try {
        await MostlyGoodMetrics.configure(
          const MGMConfiguration(
            apiKey: 'test-api-key',
            trackAppLifecycleEvents: false,
            flushInterval: 3600,
          ),
          eventStorage: storage,
          stateStorage: InMemoryStateStorage(),
          networkClient: MockNetworkClient(),
        );

        await runZonedGuarded(
          () async {
            MostlyGoodMetrics.track('write_failure');
            await Future<void>.delayed(const Duration(seconds: 2));
          },
          (error, stackTrace) => unhandledErrors.add(error),
        );

        expect(unhandledErrors, isEmpty);
        expect(
          persistenceAttempts,
          inInclusiveRange(4, 10),
          reason: 'Retries should back off instead of running about 53 times',
        );
        expect(
          await File('${documentsDirectory.path}/mgm_events.json.tmp').exists(),
          false,
        );
      } finally {
        if (await blockedTarget.exists()) await blockedTarget.delete();
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (!await persistedFile.exists() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await watcher.cancel();
      }

      expect(await persistedFile.exists(), true);
      final persisted = json.decode(await persistedFile.readAsString()) as List;
      expect(persisted, hasLength(1));
      expect(
        (persisted.single as Map<String, dynamic>)['name'],
        'write_failure',
      );

      await storage
          .store(createFileEvent(2001))
          .timeout(const Duration(seconds: 1));
      final afterReset =
          json.decode(await persistedFile.readAsString()) as List<dynamic>;
      expect(afterReset, hasLength(2));
      expect(
        await File('${documentsDirectory.path}/mgm_events.json.tmp').exists(),
        false,
      );
    });

    test('assigns IDs while preserving legacy events in a capped flush race',
        () async {
      final legacyEvents = [
        for (var index = 1; index <= 3; index++)
          createFileEvent(index).toJson()..remove('client_event_id'),
      ];
      final file = File('${documentsDirectory.path}/mgm_events.json');
      await file.writeAsString(json.encode(legacyEvents));
      final storage = FileEventStorage(maxStoredEvents: 3);

      final sentEvents = await storage.fetchEvents(2);
      await storage.store(createFileEvent(4));
      await storage.removeEventsByClientEventId(sentEvents);

      final remaining = await storage.fetchEvents(3);
      expect(remaining.map((event) => event.name), ['event_3', 'event_4']);
      expect(remaining.first.clientEventId, isNotEmpty);

      final persisted = json.decode(await file.readAsString()) as List<dynamic>;
      expect(persisted, hasLength(2));
      expect(
        (persisted.first as Map<String, dynamic>)
            .containsKey('client_event_id'),
        true,
      );
    });
  });
}
