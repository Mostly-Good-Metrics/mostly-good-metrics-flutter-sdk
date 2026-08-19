import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// Utility functions for the MostlyGoodMetrics SDK.
class MGMUtils {
  /// Regular expression for validating event names.
  /// Event names must start with a letter (or $) and contain only
  /// alphanumeric characters, underscores, and spaces.
  static final RegExp _eventNameRegex =
      RegExp(r'^(\$)?[a-zA-Z][a-zA-Z0-9_ ]*$');

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
          'alphanumeric characters, underscores, and spaces';
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

  /// Generates a random alphanumeric string of the given length.
  static String generateRandomString(int length) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)])
        .join();
  }

  /// Generates an anonymous user ID with $anon_ prefix.
  /// Format: $anon_xxxxxxxxxxxx (12 random alphanumeric chars)
  static String generateAnonymousId() {
    return '\$anon_${generateRandomString(12)}';
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

  /// Matches a numeric version like "17", "17.0" or "26.5.2".
  static final RegExp _numericVersionRegex = RegExp(r'\d+(\.\d+){1,2}');

  /// Clean numeric OS version resolved once via [resolveOSVersion] and cached.
  static String? _osVersion;

  /// Extracts a numeric version (e.g. "17.0") from a verbose platform string
  /// such as `"Version 17.0 (Build 21A329)"`. Returns null if none is found.
  ///
  /// Note: this is unreliable for Android, whose
  /// [Platform.operatingSystemVersion] is a build id (e.g. "QKR1.191246.002")
  /// with no real OS version — use [resolveOSVersion] there instead.
  @visibleForTesting
  static String? extractNumericVersion(String raw) =>
      _numericVersionRegex.stringMatch(raw);

  /// Resolves a clean, numeric OS version per platform and caches it so the
  /// synchronous [getOSVersion] can return it during event construction.
  ///
  /// Uses `device_info_plus` because Dart's [Platform.operatingSystemVersion]
  /// is verbose on iOS/macOS ("Version 17.0 (Build 21A329)") and, on Android,
  /// is a build id with no OS version at all.
  ///
  /// Call once during SDK configure. [deviceInfo] is injectable for testing.
  static Future<String?> resolveOSVersion({
    DeviceInfoPlugin? deviceInfo,
  }) async {
    if (kIsWeb) {
      _osVersion = null;
      return null;
    }

    try {
      _osVersion = await _osVersionFromDeviceInfo(
        deviceInfo ?? DeviceInfoPlugin(),
        isAndroid: Platform.isAndroid,
        isIOS: Platform.isIOS,
        isMacOS: Platform.isMacOS,
      );
    } catch (_) {
      // device_info_plus unavailable (e.g. unsupported desktop platform or a
      // missing plugin in tests): fall back to the best-effort extraction,
      // which getOSVersion() performs when the cache is empty.
      _osVersion = null;
    }

    return getOSVersion();
  }

  /// Maps device_info_plus results to a numeric version for the given platform.
  /// Split out from [resolveOSVersion] so it can be unit-tested with a mocked
  /// [DeviceInfoPlugin] independent of the host platform.
  @visibleForTesting
  static Future<String?> osVersionFromDeviceInfo(
    DeviceInfoPlugin deviceInfo, {
    required bool isAndroid,
    required bool isIOS,
    required bool isMacOS,
  }) =>
      _osVersionFromDeviceInfo(
        deviceInfo,
        isAndroid: isAndroid,
        isIOS: isIOS,
        isMacOS: isMacOS,
      );

  static Future<String?> _osVersionFromDeviceInfo(
    DeviceInfoPlugin deviceInfo, {
    required bool isAndroid,
    required bool isIOS,
    required bool isMacOS,
  }) async {
    if (isAndroid) {
      // e.g. "14" — the real OS version, not the build id.
      return (await deviceInfo.androidInfo).version.release;
    }
    if (isIOS) {
      // e.g. "17.0"
      return (await deviceInfo.iosInfo).systemVersion;
    }
    if (isMacOS) {
      final info = await deviceInfo.macOsInfo;
      // e.g. "26.5.2"
      return '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
    }
    // Other platforms (Linux/Windows/etc.): the raw string is already a
    // real version, just strip any surrounding noise.
    return extractNumericVersion(Platform.operatingSystemVersion);
  }

  /// Gets the clean numeric OS version string (e.g. "17.0", "26.5.2", "14").
  ///
  /// Returns the value cached by [resolveOSVersion]. Before that has run it
  /// falls back to extracting a numeric version from
  /// [Platform.operatingSystemVersion] — valid on iOS/macOS/desktop but not
  /// Android (build id), where null is returned rather than a garbage value.
  static String? getOSVersion() {
    if (kIsWeb) {
      return null; // Web doesn't have direct OS version access
    }

    if (_osVersion != null) {
      return _osVersion;
    }

    // Cache not yet populated by resolveOSVersion(). Android's raw string is a
    // build id with no OS version, so we return null there instead of parsing
    // garbage; device_info_plus supplies the correct value once resolved.
    if (Platform.isAndroid) {
      return null;
    }

    return extractNumericVersion(Platform.operatingSystemVersion);
  }

  /// Resets the cached OS version. Test-only.
  @visibleForTesting
  static void resetOSVersionCache() => _osVersion = null;

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

  /// Converts a string to snake_case.
  ///
  /// Byte-for-byte port of the JS SDK's transform:
  /// 1. insert `_` before every uppercase letter
  /// 2. replace runs of hyphens/whitespace with a single `_`
  /// 3. lowercase
  /// 4. strip one leading `_`
  ///
  /// Other punctuation is left untouched.
  /// Example: "ABTest" -> "a_b_test"
  /// Example: "Pricing-Test V2" -> "pricing__test__v2"
  static String toSnakeCase(String input) {
    return input
        .replaceAllMapped(RegExp(r'([A-Z])'), (match) => '_${match.group(1)}')
        .replaceAll(RegExp(r'[-\s]+'), '_')
        .toLowerCase()
        .replaceFirst(RegExp(r'^_'), '');
  }
}
