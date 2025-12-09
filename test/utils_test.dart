import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics/src/utils.dart';

void main() {
  group('MGMUtils.validateEventName', () {
    test('accepts valid event names', () {
      expect(MGMUtils.validateEventName('button_clicked'), null);
      expect(MGMUtils.validateEventName('pageView'), null);
      expect(MGMUtils.validateEventName('a'), null);
      expect(MGMUtils.validateEventName('event123'), null);
      expect(MGMUtils.validateEventName('Event_Name_123'), null);
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
      expect(MGMUtils.validateEventName('event name'), isNotNull);
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
}
