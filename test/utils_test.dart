import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mostly_good_metrics_flutter/src/utils.dart';

class _MockDeviceInfoPlugin extends Mock implements DeviceInfoPlugin {}

class _MockAndroidDeviceInfo extends Mock implements AndroidDeviceInfo {}

class _MockAndroidBuildVersion extends Mock implements AndroidBuildVersion {}

class _MockIosDeviceInfo extends Mock implements IosDeviceInfo {}

class _MockMacOsDeviceInfo extends Mock implements MacOsDeviceInfo {}

/// A clean, numeric OS version: "17", "17.0" or "26.5.2".
/// No "Version" / "Build" prefixes and no Android build ids.
final _numericOSVersion = RegExp(r'^[0-9]+(\.[0-9]+){0,2}$');

void main() {
  group('MGMUtils.validateEventName', () {
    test('accepts valid event names', () {
      expect(MGMUtils.validateEventName('button_clicked'), null);
      expect(MGMUtils.validateEventName('pageView'), null);
      expect(MGMUtils.validateEventName('a'), null);
      expect(MGMUtils.validateEventName('event123'), null);
      expect(MGMUtils.validateEventName('Event_Name_123'), null);
      expect(MGMUtils.validateEventName('Button Clicked'), null);
      expect(MGMUtils.validateEventName('User Signed Up'), null);
    });

    test(r'accepts system event names with $ prefix', () {
      expect(MGMUtils.validateEventName(r'$app_opened'), null);
      expect(MGMUtils.validateEventName(r'$app_backgrounded'), null);
      expect(MGMUtils.validateEventName(r'$app_installed'), null);
      expect(MGMUtils.validateEventName(r'$app_updated'), null);
    });

    test('rejects empty event names', () {
      final error = MGMUtils.validateEventName('');
      expect(error, 'Event name cannot be empty');
    });

    test('rejects event names starting with numbers', () {
      final error = MGMUtils.validateEventName('123event');
      expect(error, isNotNull);
      expect(error, contains('must start with a letter'));
    });

    test('rejects event names starting with underscore', () {
      final error = MGMUtils.validateEventName('_event');
      expect(error, isNotNull);
      expect(error, contains('must start with a letter'));
    });

    test('rejects event names with invalid characters', () {
      expect(MGMUtils.validateEventName('event-name'), isNotNull);
      expect(MGMUtils.validateEventName('event.name'), isNotNull);
      expect(MGMUtils.validateEventName('event@name'), isNotNull);
    });

    test('rejects event names exceeding max length', () {
      final longName = 'a' * 256;
      final error = MGMUtils.validateEventName(longName);
      expect(error, contains('exceeds maximum length'));
    });

    test('accepts event names at max length', () {
      final maxName = 'a' * 255;
      expect(MGMUtils.validateEventName(maxName), null);
    });
  });

  group('MGMUtils.validateProperties', () {
    test('accepts null properties', () {
      expect(MGMUtils.validateProperties(null), null);
    });

    test('accepts empty properties', () {
      expect(MGMUtils.validateProperties({}), null);
    });

    test('accepts flat properties', () {
      final props = {
        'string': 'value',
        'number': 42,
        'boolean': true,
        'double': 3.14,
      };
      expect(MGMUtils.validateProperties(props), null);
    });

    test('accepts properties with nested objects up to 3 levels', () {
      final props = {
        'level1': {
          'level2': {
            'level3': 'value',
          },
        },
      };
      expect(MGMUtils.validateProperties(props), null);
    });

    test('rejects properties nested beyond 3 levels', () {
      final props = {
        'level1': {
          'level2': {
            'level3': {
              'level4': 'too deep',
            },
          },
        },
      };
      final error = MGMUtils.validateProperties(props);
      expect(error, contains('maximum nesting depth'));
    });

    test('accepts properties with lists', () {
      final props = {
        'items': ['a', 'b', 'c'],
        'numbers': [1, 2, 3],
      };
      expect(MGMUtils.validateProperties(props), null);
    });

    test('accepts properties with objects in lists', () {
      final props = {
        'users': [
          {'name': 'Alice'},
          {'name': 'Bob'},
        ],
      };
      expect(MGMUtils.validateProperties(props), null);
    });

    test('rejects deeply nested objects in lists', () {
      final props = {
        'items': [
          {
            'nested': {
              'deeper': {
                'too_deep': {
                  'value': 'fail',
                },
              },
            },
          },
        ],
      };
      final error = MGMUtils.validateProperties(props);
      expect(error, contains('maximum nesting depth'));
    });
  });

  group('MGMUtils.generateUUID', () {
    test('generates valid UUID format', () {
      final uuid = MGMUtils.generateUUID();

      // UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      expect(uuid.length, 36);
      expect(uuid[8], '-');
      expect(uuid[13], '-');
      expect(uuid[18], '-');
      expect(uuid[23], '-');
    });

    test('generates version 4 UUID', () {
      final uuid = MGMUtils.generateUUID();

      // Version 4 has '4' as the first character of the 3rd group
      expect(uuid[14], '4');
    });

    test('generates RFC 4122 variant UUID', () {
      final uuid = MGMUtils.generateUUID();

      // Variant bits: first character of 4th group should be 8, 9, a, or b
      final variantChar = uuid[19].toLowerCase();
      expect(['8', '9', 'a', 'b'].contains(variantChar), true);
    });

    test('generates unique UUIDs', () {
      final uuids = <String>{};
      for (var i = 0; i < 1000; i++) {
        uuids.add(MGMUtils.generateUUID());
      }
      // All generated UUIDs should be unique
      expect(uuids.length, 1000);
    });

    test('contains only valid hex characters and dashes', () {
      final uuid = MGMUtils.generateUUID();
      final validChars = RegExp(r'^[0-9a-f\-]+$');
      expect(validChars.hasMatch(uuid.toLowerCase()), true);
    });
  });

  group('MGMUtils.getPlatformName', () {
    test('returns a non-empty string', () {
      final platform = MGMUtils.getPlatformName();
      expect(platform.isNotEmpty, true);
    });

    test('returns a valid platform name', () {
      final platform = MGMUtils.getPlatformName();
      final validPlatforms = [
        'ios',
        'android',
        'macos',
        'windows',
        'linux',
        'fuchsia',
        'web',
        'unknown',
      ];
      expect(validPlatforms.contains(platform), true);
    });
  });

  group('MGMUtils.getOSVersion (MGM-203)', () {
    tearDown(MGMUtils.resetOSVersionCache);

    test('extractNumericVersion strips verbose iOS/macOS strings', () {
      // iOS/macOS: "Version 17.0 (Build 21A329)" -> "17.0"
      expect(
        MGMUtils.extractNumericVersion('Version 17.0 (Build 21A329)'),
        '17.0',
      );
      expect(
        MGMUtils.extractNumericVersion('Version 26.5.2 (Build 25F74)'),
        '26.5.2',
      );
      // Plain numeric strings pass through.
      expect(MGMUtils.extractNumericVersion('14.5'), '14.5');
      // No version present -> null.
      expect(MGMUtils.extractNumericVersion('no digits here'), null);
    });

    test('resolveOSVersion caches a clean numeric value for getOSVersion', () async {
      final resolved = await MGMUtils.resolveOSVersion();
      final emitted = MGMUtils.getOSVersion();

      // getOSVersion() reflects the resolved cache.
      expect(emitted, resolved);
      // The emitted value must be numeric with no "Version"/"Build"/build ids.
      expect(emitted, isNotNull);
      expect(emitted, matches(_numericOSVersion));
      expect(emitted, isNot(contains('Version')));
      expect(emitted, isNot(contains('Build')));
    });

    test('osVersionFromDeviceInfo returns AndroidBuildVersion.release', () async {
      final plugin = _MockDeviceInfoPlugin();
      final info = _MockAndroidDeviceInfo();
      final version = _MockAndroidBuildVersion();
      when(() => plugin.androidInfo).thenAnswer((_) async => info);
      when(() => info.version).thenReturn(version);
      when(() => version.release).thenReturn('14');

      final result = await MGMUtils.osVersionFromDeviceInfo(
        plugin,
        isAndroid: true,
        isIOS: false,
        isMacOS: false,
      );

      expect(result, '14');
      expect(result, matches(_numericOSVersion));
    });

    test('osVersionFromDeviceInfo returns iOS systemVersion', () async {
      final plugin = _MockDeviceInfoPlugin();
      final info = _MockIosDeviceInfo();
      when(() => plugin.iosInfo).thenAnswer((_) async => info);
      when(() => info.systemVersion).thenReturn('17.0');

      final result = await MGMUtils.osVersionFromDeviceInfo(
        plugin,
        isAndroid: false,
        isIOS: true,
        isMacOS: false,
      );

      expect(result, '17.0');
      expect(result, matches(_numericOSVersion));
    });

    test('osVersionFromDeviceInfo composes macOS version parts', () async {
      final plugin = _MockDeviceInfoPlugin();
      final info = _MockMacOsDeviceInfo();
      when(() => plugin.macOsInfo).thenAnswer((_) async => info);
      when(() => info.majorVersion).thenReturn(26);
      when(() => info.minorVersion).thenReturn(5);
      when(() => info.patchVersion).thenReturn(2);

      final result = await MGMUtils.osVersionFromDeviceInfo(
        plugin,
        isAndroid: false,
        isIOS: false,
        isMacOS: true,
      );

      expect(result, '26.5.2');
      expect(result, matches(_numericOSVersion));
    });
  });

  group('MGMUtils.toSnakeCase', () {
    test('converts spaces to underscores', () {
      // An uppercase letter after a space yields a double underscore
      // (underscore inserted before the uppercase, plus the space).
      expect(MGMUtils.toSnakeCase('My Experiment'), 'my__experiment');
      expect(MGMUtils.toSnakeCase('User Signed Up'), 'user__signed__up');
      expect(MGMUtils.toSnakeCase('my experiment'), 'my_experiment');
    });

    test('converts hyphens to underscores', () {
      expect(MGMUtils.toSnakeCase('my-experiment'), 'my_experiment');
      expect(MGMUtils.toSnakeCase('user-signed-up'), 'user_signed_up');
    });

    test('converts camelCase to snake_case', () {
      expect(MGMUtils.toSnakeCase('myExperiment'), 'my_experiment');
      expect(MGMUtils.toSnakeCase('userSignedUp'), 'user_signed_up');
    });

    test('converts PascalCase to snake_case', () {
      expect(MGMUtils.toSnakeCase('MyExperiment'), 'my_experiment');
      expect(MGMUtils.toSnakeCase('UserSignedUp'), 'user_signed_up');
    });

    test('handles already snake_case strings', () {
      expect(MGMUtils.toSnakeCase('my_experiment'), 'my_experiment');
      expect(MGMUtils.toSnakeCase('user_signed_up'), 'user_signed_up');
    });

    test('handles empty string', () {
      expect(MGMUtils.toSnakeCase(''), '');
    });

    test('handles single word', () {
      expect(MGMUtils.toSnakeCase('experiment'), 'experiment');
      expect(MGMUtils.toSnakeCase('Experiment'), 'experiment');
    });

    test('handles mixed formats', () {
      expect(MGMUtils.toSnakeCase('My camelCase-test'), 'my_camel_case_test');
    });

    test('matches the JS reference transform byte-for-byte', () {
      expect(MGMUtils.toSnakeCase('Pricing-Test V2'), 'pricing__test__v2');
      expect(MGMUtils.toSnakeCase('A-B-Test'), 'a__b__test');
      expect(MGMUtils.toSnakeCase('ABTest'), 'a_b_test');
      expect(MGMUtils.toSnakeCase('button-color'), 'button_color');
      expect(MGMUtils.toSnakeCase('myExperiment2'), 'my_experiment2');
      expect(MGMUtils.toSnakeCase('a--b'), 'a_b');
    });

    test('does not transform other punctuation', () {
      expect(MGMUtils.toSnakeCase('exp.name'), 'exp.name');
      expect(MGMUtils.toSnakeCase('exp/name!'), 'exp/name!');
    });
  });
}
