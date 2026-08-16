import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/src/network.dart';

void main() {
  group('sdkVersion', () {
    test('is a non-blank semantic version', () {
      expect(sdkVersion.trim(), isNotEmpty);
      expect(RegExp(r'^\d+\.\d+\.\d+').hasMatch(sdkVersion), isTrue);
    });

    test('matches the version declared in pubspec.yaml', () {
      // Guards against the header version drifting from the published package
      // version (the bug this addresses: sdkVersion was stuck at 0.2.6 while
      // the package had moved to 0.3.0).
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match =
          RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(pubspec);
      expect(match, isNotNull, reason: 'could not find version in pubspec.yaml');
      final pubspecVersion = match!.group(1)!.trim();
      expect(sdkVersion, pubspecVersion);
    });
  });
}
