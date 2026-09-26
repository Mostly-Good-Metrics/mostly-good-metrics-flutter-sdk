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

      await Future.wait([
        for (var index = 0; index < 100; index++)
          storage.store(createFileEvent(index)),
      ]);

      final stored = await storage.fetchEvents(100);
      expect(stored.map((event) => event.name), [
        for (var index = 0; index < 100; index++) 'event_$index',
      ]);

      final file = File('${documentsDirectory.path}/mgm_events.json');
      final persisted = json.decode(await file.readAsString()) as List<dynamic>;
      expect(persisted, hasLength(100));
      expect(
        persisted.map((event) => (event as Map<String, dynamic>)['name']),
        [for (var index = 0; index < 100; index++) 'event_$index'],
      );
    });

    test('preserves the existing JSON array format', () async {
      final storage = FileEventStorage(maxStoredEvents: 10000);
      await storage.store(createFileEvent(1));

      final file = File('${documentsDirectory.path}/mgm_events.json');
      final persisted = json.decode(await file.readAsString()) as List<dynamic>;

      expect(persisted.single, createFileEvent(1).toJson());
    });
  });
}
