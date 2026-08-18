import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/src/network.dart';

/// Guards against `sdkVersion` (reported via the `X-MGM-SDK-Version` header)
/// drifting out of sync with the package version in `pubspec.yaml`.
void main() {
  test('sdkVersion matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(.+)$', multiLine: true)
        .firstMatch(pubspec);

    expect(match, isNotNull, reason: 'version not found in pubspec.yaml');

    final pubspecVersion = match!.group(1)!.trim();
    expect(
      sdkVersion,
      pubspecVersion,
      reason: 'lib/src/network.dart sdkVersion ($sdkVersion) is out of sync '
          'with pubspec.yaml version ($pubspecVersion). Update the constant '
          'when bumping the package version.',
    );
  });
}
