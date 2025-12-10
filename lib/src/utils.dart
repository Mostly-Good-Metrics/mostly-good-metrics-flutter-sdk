import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Utility functions for the MostlyGoodMetrics SDK.
class MGMUtils {
  /// Regular expression for validating event names.
  /// Event names must start with a letter (or $) and contain only
  /// alphanumeric characters and underscores.
  static final RegExp _eventNameRegex = RegExp(r'^(\$)?[a-zA-Z][a-zA-Z0-9_]*$');

  /// Maximum length for event names.
  static const int maxEventNameLength = 255;

  /// Maximum depth for nested properties.
  static const int maxPropertyDepth = 3;

  /// Validates an event name.
  /// Returns null if valid, or an error message if invalid.
  static String? validateEventName(String name) {
    if (name.isEmpty) {
      return 'Event name cannot be empty';
    }

    if (name.length > maxEventNameLength) {
      return 'Event name exceeds maximum length of $maxEventNameLength characters';
    }

    if (!_eventNameRegex.hasMatch(name)) {
      return 'Event name must start with a letter (or \$) and contain only '
          'alphanumeric characters and underscores';
    }

    return null;
  }

  /// Validates event properties.
  /// Returns null if valid, or an error message if invalid.
  static String? validateProperties(
    Map<String, dynamic>? properties, [
    int depth = 0,
  ]) {
    if (properties == null) return null;

    if (depth >= maxPropertyDepth) {
      return 'Properties exceed maximum nesting depth of $maxPropertyDepth';
    }

    for (final entry in properties.entries) {
      if (entry.value is Map<String, dynamic>) {
        final error = validateProperties(
          entry.value as Map<String, dynamic>,
          depth + 1,
        );
        if (error != null) return error;
      } else if (entry.value is List) {
        for (final item in entry.value as List) {
          if (item is Map<String, dynamic>) {
            final error = validateProperties(item, depth + 1);
            if (error != null) return error;
          }
        }
      }
    }

    return null;
  }

  /// Generates a UUID v4 string.
  static String generateUUID() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // Set version (4) and variant (RFC 4122)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// Gets the current platform name.
  static String getPlatformName() {
    if (kIsWeb) {
      return 'web';
    }

    if (Platform.isIOS) {
      return 'ios';
    } else if (Platform.isAndroid) {
      return 'android';
    } else if (Platform.isMacOS) {
      return 'macos';
    } else if (Platform.isWindows) {
      return 'windows';
    } else if (Platform.isLinux) {
      return 'linux';
    } else if (Platform.isFuchsia) {
      return 'fuchsia';
    }

    return 'unknown';
  }

  /// Gets the OS version string.
  static String? getOSVersion() {
    if (kIsWeb) {
      return null; // Web doesn't have direct OS version access
    }

    return Platform.operatingSystemVersion;
  }

  /// Gets the user's locale (e.g., "en_US").
  static String getLocale() {
    return Platform.localeName;
  }

  /// Gets the user's timezone name.
  /// Note: This returns the offset-based name (e.g., "EST" or "UTC+5"),
  /// not the IANA timezone. For IANA names, use the intl package.
  static String getTimezone() {
    return DateTime.now().timeZoneName;
  }

  /// Gets the device manufacturer.
  /// Returns "Apple" for iOS/macOS, or null for other platforms
  /// (Android requires platform channel for Build.MANUFACTURER).
  static String? getDeviceManufacturer() {
    if (kIsWeb) {
      return null;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return 'Apple';
    }

    // For Android, this would require a platform channel to access Build.MANUFACTURER
    // Returning null here since we don't want to add platform channel complexity
    return null;
  }
}
