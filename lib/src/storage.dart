import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';
import 'types.dart';

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

/// Abstract interface for persistent state storage.
abstract class StateStorage {
  /// Get a string value.
  Future<String?> getString(String key);

  /// Set a string value.
  Future<void> setString(String key, String? value);
}

/// File-based event storage implementation.
/// Uses JSON file storage for events and SharedPreferences for metadata.
class FileEventStorage implements EventStorage {
  static const String _eventsFileName = 'mgm_events.json';
  static const String _prefsPrefix = 'mgm_';

  final int _maxStoredEvents;
  List<MGMEvent>? _cachedEvents;
  String? _eventsFilePath;
  bool _initialized = false;

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

  Future<List<MGMEvent>> _loadEvents() async {
    if (_cachedEvents != null) return _cachedEvents!;

    await _ensureInitialized();

    if (kIsWeb) {
      // For web, use SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final eventsJson = prefs.getString('${_prefsPrefix}events');
      if (eventsJson != null) {
        try {
          final List<dynamic> eventsList = json.decode(eventsJson) as List;
          _cachedEvents = eventsList
              .map((e) => MGMEvent.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (e) {
          MGMLogger.error('Failed to parse stored events', e);
          _cachedEvents = [];
        }
      } else {
        _cachedEvents = [];
      }
    } else {
      // For mobile/desktop, use file storage
      final file = File(_eventsFilePath!);
      if (await file.exists()) {
        try {
          final contents = await file.readAsString();
          final List<dynamic> eventsList = json.decode(contents) as List;
          _cachedEvents = eventsList
              .map((e) => MGMEvent.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (e) {
          MGMLogger.error('Failed to load events from file', e);
          _cachedEvents = [];
        }
      } else {
        _cachedEvents = [];
      }
    }

    return _cachedEvents!;
  }

  Future<void> _saveEvents() async {
    if (_cachedEvents == null) return;

    await _ensureInitialized();

    final eventsJson = json.encode(
      _cachedEvents!.map((e) => e.toJson()).toList(),
    );

    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${_prefsPrefix}events', eventsJson);
    } else {
      final file = File(_eventsFilePath!);
      await file.writeAsString(eventsJson);
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

    await _saveEvents();
    MGMLogger.debug('Stored event: ${event.name}');
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
      await _saveEvents();
      MGMLogger.debug('Removed $removeCount events');
    }
  }

  @override
  Future<int> eventCount() async {
    final events = await _loadEvents();
    return events.length;
  }

  @override
  Future<void> clear() async {
    _cachedEvents = [];
    await _saveEvents();
    MGMLogger.debug('Cleared all events');
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
class InMemoryEventStorage implements EventStorage {
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
