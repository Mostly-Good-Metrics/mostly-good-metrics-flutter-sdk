import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';
import 'types.dart';

String _encodeEvents(List<MGMEvent> events) => json.encode(
      events.map((event) => event.toJson()).toList(growable: false),
    );

/// Abstract interface for event storage.
abstract class EventStorage {
  /// Store an event.
  Future<void> store(MGMEvent event);

  /// Fetch events up to the specified limit.
  Future<List<MGMEvent>> fetchEvents(int limit);

  /// Remove the specified number of events from the front.
  Future<void> removeEvents(int count);

  /// Get the current number of stored events.
  Future<int> eventCount();

  /// Clear all stored events.
  Future<void> clear();
}

/// Optional capability for removing sent events by their client event IDs.
///
/// Custom storage adapters can implement this alongside [EventStorage] to
/// avoid removing unsent events if the queue is trimmed during a flush.
abstract class ClientEventIdEventStorage {
  /// Remove events matching the supplied client event IDs.
  Future<void> removeEventsByClientEventId(List<MGMEvent> events);
}

/// Abstract interface for persistent state storage.
abstract class StateStorage {
  /// Get a string value.
  Future<String?> getString(String key);

  /// Set a string value.
  Future<void> setString(String key, String? value);
}

/// File-based event storage implementation.
/// Uses JSON file storage for events and SharedPreferences for metadata.
class FileEventStorage implements EventStorage, ClientEventIdEventStorage {
  static const String _eventsFileName = 'mgm_events.json';
  static const String _prefsPrefix = 'mgm_';
  static const Duration _persistenceDelay = Duration(milliseconds: 25);
  static const int _serializationChunkSize = 2500;

  final int _maxStoredEvents;
  List<MGMEvent>? _cachedEvents;
  Future<List<MGMEvent>>? _loadingEvents;
  String? _eventsFilePath;
  bool _initialized = false;
  Timer? _persistenceTimer;
  Future<void>? _activePersistence;
  Completer<void>? _pendingPersistence;
  int _revision = 0;
  int _persistedRevision = 0;

  FileEventStorage({required int maxStoredEvents})
      : _maxStoredEvents = maxStoredEvents;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    if (!kIsWeb) {
      final directory = await getApplicationDocumentsDirectory();
      _eventsFilePath = '${directory.path}/$_eventsFileName';
    }
    _initialized = true;
  }

  Future<List<MGMEvent>> _loadEvents() {
    if (_cachedEvents != null) return Future.value(_cachedEvents!);

    final loadingEvents = _loadingEvents;
    if (loadingEvents != null) return loadingEvents;

    final load = _readEvents();
    _loadingEvents = load;
    return load.whenComplete(() => _loadingEvents = null);
  }

  Future<List<MGMEvent>> _readEvents() async {
    await _ensureInitialized();

    late final List<MGMEvent> events;
    if (kIsWeb) {
      // For web, use SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final eventsJson = prefs.getString('${_prefsPrefix}events');
      if (eventsJson != null) {
        try {
          final List<dynamic> eventsList = json.decode(eventsJson) as List;
          events = eventsList
              .map((e) => MGMEvent.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (e) {
          MGMLogger.error('Failed to parse stored events', e);
          events = [];
        }
      } else {
        events = [];
      }
    } else {
      // For mobile/desktop, use file storage
      final file = File(_eventsFilePath!);
      if (await file.exists()) {
        try {
          final contents = await file.readAsString();
          final List<dynamic> eventsList = json.decode(contents) as List;
          events = eventsList
              .map((e) => MGMEvent.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (e) {
          MGMLogger.error('Failed to load events from file', e);
          events = [];
        }
      } else {
        events = [];
      }
    }

    _cachedEvents = events;
    return events;
  }

  Future<void> _saveSnapshot(List<MGMEvent> snapshot) async {
    await _ensureInitialized();

    if (kIsWeb) {
      final eventsJson = await compute(
        _encodeEvents,
        snapshot,
        debugLabel: 'MostlyGoodMetrics.encodeEvents',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${_prefsPrefix}events', eventsJson);
    } else {
      final file = File(_eventsFilePath!);
      final temporaryFile = File('${file.path}.tmp');
      final sink = temporaryFile.openWrite();
      try {
        sink.write('[');
        for (var start = 0;
            start < snapshot.length;
            start += _serializationChunkSize) {
          final end =
              (start + _serializationChunkSize).clamp(0, snapshot.length);
          final eventsJson = await compute(
            _encodeEvents,
            snapshot.sublist(start, end),
            debugLabel: 'MostlyGoodMetrics.encodeEvents',
          );
          if (start > 0) sink.write(',');
          sink.write(eventsJson.substring(1, eventsJson.length - 1));
        }
        sink.write(']');
        await sink.flush();
      } finally {
        await sink.close();
      }
      await temporaryFile.rename(file.path);
    }
  }

  Future<void> _schedulePersistence() {
    _revision++;
    final pending = _pendingPersistence ??= Completer<void>();

    _persistenceTimer?.cancel();
    _persistenceTimer = Timer(_persistenceDelay, _startPersistence);

    return pending.future;
  }

  void _startPersistence() {
    _persistenceTimer = null;
    if (_activePersistence != null) return;

    final persistence = _persistUntilCurrent();
    _activePersistence = persistence;
  }

  Future<void> _persistUntilCurrent() async {
    try {
      while (_persistedRevision != _revision) {
        final revision = _revision;
        final snapshot = List<MGMEvent>.of(_cachedEvents!);
        await _saveSnapshot(snapshot);
        _persistedRevision = revision;
      }

      final pending = _pendingPersistence;
      _pendingPersistence = null;
      pending?.complete();
    } catch (error, stackTrace) {
      final pending = _pendingPersistence;
      _pendingPersistence = null;
      pending?.completeError(error, stackTrace);
    } finally {
      _activePersistence = null;

      // A timer that fired during the write delegates the newer revision to
      // this loop. Schedule a retry only if a mutation landed after the loop
      // completed but before cleanup.
      if (_pendingPersistence != null &&
          _persistedRevision != _revision &&
          _persistenceTimer == null) {
        _persistenceTimer = Timer(_persistenceDelay, _startPersistence);
      }
    }
  }

  @override
  Future<void> store(MGMEvent event) async {
    final events = await _loadEvents();

    events.add(event);

    // Trim to max stored events (FIFO)
    while (events.length > _maxStoredEvents) {
      events.removeAt(0);
    }

    final persistence = _schedulePersistence();
    MGMLogger.debug('Stored event: ${event.name}');
    await persistence;
  }

  @override
  Future<List<MGMEvent>> fetchEvents(int limit) async {
    final events = await _loadEvents();
    final fetchLimit = limit.clamp(0, events.length);
    return events.take(fetchLimit).toList();
  }

  @override
  Future<void> removeEvents(int count) async {
    final events = await _loadEvents();
    final removeCount = count.clamp(0, events.length);

    if (removeCount > 0) {
      events.removeRange(0, removeCount);
      final persistence = _schedulePersistence();
      MGMLogger.debug('Removed $removeCount events');
      await persistence;
    }
  }

  @override
  Future<void> removeEventsByClientEventId(List<MGMEvent> sentEvents) async {
    final events = await _loadEvents();
    final sentIds = sentEvents
        .map((event) => event.clientEventId)
        .where((eventId) => eventId.isNotEmpty)
        .toSet();
    final sentLegacyEvents = Set<MGMEvent>.identity()
      ..addAll(sentEvents.where((event) => event.clientEventId.isEmpty));
    final previousCount = events.length;

    events.removeWhere((event) {
      final eventId = event.clientEventId;
      return eventId.isEmpty
          ? sentLegacyEvents.contains(event)
          : sentIds.contains(eventId);
    });

    final removedCount = previousCount - events.length;
    if (removedCount > 0) {
      final persistence = _schedulePersistence();
      MGMLogger.debug('Removed $removedCount events');
      await persistence;
    }
  }

  @override
  Future<int> eventCount() async {
    final events = await _loadEvents();
    return events.length;
  }

  @override
  Future<void> clear() async {
    final events = await _loadEvents();
    events.clear();
    final persistence = _schedulePersistence();
    MGMLogger.debug('Cleared all events');
    await persistence;
  }
}

/// SharedPreferences-based state storage implementation.
class PreferencesStateStorage implements StateStorage {
  static const String _prefsPrefix = 'mgm_';

  @override
  Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefsPrefix$key');
  }

  @override
  Future<void> setString(String key, String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove('$_prefsPrefix$key');
    } else {
      await prefs.setString('$_prefsPrefix$key', value);
    }
  }
}

/// In-memory event storage for testing.
class InMemoryEventStorage implements EventStorage, ClientEventIdEventStorage {
  final List<MGMEvent> _events = [];
  final int _maxStoredEvents;

  InMemoryEventStorage({int maxStoredEvents = 10000})
      : _maxStoredEvents = maxStoredEvents;

  @override
  Future<void> store(MGMEvent event) async {
    _events.add(event);
    while (_events.length > _maxStoredEvents) {
      _events.removeAt(0);
    }
  }

  @override
  Future<List<MGMEvent>> fetchEvents(int limit) async {
    final fetchLimit = limit.clamp(0, _events.length);
    return _events.take(fetchLimit).toList();
  }

  @override
  Future<void> removeEvents(int count) async {
    final removeCount = count.clamp(0, _events.length);
    if (removeCount > 0) {
      _events.removeRange(0, removeCount);
    }
  }

  @override
  Future<void> removeEventsByClientEventId(List<MGMEvent> sentEvents) async {
    final sentIds = sentEvents
        .map((event) => event.clientEventId)
        .where((eventId) => eventId.isNotEmpty)
        .toSet();
    final sentLegacyEvents = Set<MGMEvent>.identity()
      ..addAll(sentEvents.where((event) => event.clientEventId.isEmpty));

    _events.removeWhere((event) {
      final eventId = event.clientEventId;
      return eventId.isEmpty
          ? sentLegacyEvents.contains(event)
          : sentIds.contains(eventId);
    });
  }

  @override
  Future<int> eventCount() async => _events.length;

  @override
  Future<void> clear() async => _events.clear();
}

/// In-memory state storage for testing.
class InMemoryStateStorage implements StateStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}
