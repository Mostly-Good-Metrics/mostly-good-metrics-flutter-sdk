import 'package:flutter_test/flutter_test.dart';
import 'package:mostly_good_metrics_flutter/src/bucketing.dart';

/// Golden vectors shared across MostlyGoodMetrics SDKs.
///
/// bucket = first 8 bytes of SHA-256(utf8("<experiment_id>:<user_id>"))
/// as an unsigned big-endian 64-bit integer;
/// variant = variants[bucket % variants.length].
class _GoldenVector {
  final String experimentId;
  final String userId;
  final List<String> variants;
  final String bucket;
  final String expectedVariant;

  const _GoldenVector({
    required this.experimentId,
    required this.userId,
    required this.variants,
    required this.bucket,
    required this.expectedVariant,
  });
}

const _goldenVectors = [
  _GoldenVector(
    experimentId: '7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71',
    userId: 'user_123',
    variants: ['control', 'treatment'],
    bucket: '11452140836674321702',
    expectedVariant: 'control',
  ),
  _GoldenVector(
    experimentId: '7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71',
    userId: r'$anon_abc123def456',
    variants: ['control', 'treatment'],
    bucket: '10935638356306450407',
    expectedVariant: 'treatment',
  ),
  _GoldenVector(
    experimentId: '3f9c2d11-8b7a-4e5f-a0c6-91d2e3f4a5b6',
    userId: 'user_123',
    variants: ['a', 'b', 'c'],
    bucket: '3772238658190659659',
    expectedVariant: 'c',
  ),
  _GoldenVector(
    experimentId: '3f9c2d11-8b7a-4e5f-a0c6-91d2e3f4a5b6',
    userId: 'chris@nihongo.example',
    variants: ['a', 'b', 'c'],
    bucket: '15293329125595004806',
    expectedVariant: 'b',
  ),
  _GoldenVector(
    experimentId: 'c0ffee00-1234-5678-9abc-def012345678',
    userId: 'u',
    variants: ['on', 'off'],
    bucket: '5314609686893464838',
    expectedVariant: 'on',
  ),
  _GoldenVector(
    experimentId: 'c0ffee00-1234-5678-9abc-def012345678',
    userId: '日本語ユーザー',
    variants: ['on', 'off'],
    bucket: '15854517259962621242',
    expectedVariant: 'on',
  ),
  _GoldenVector(
    experimentId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000',
    userId: 'user_with_long_id_'
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    variants: ['v1', 'v2', 'v3', 'v4', 'v5'],
    bucket: '16479651874404423415',
    expectedVariant: 'v1',
  ),
  _GoldenVector(
    experimentId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000',
    userId: '',
    variants: ['v1', 'v2'],
    bucket: '2902893145859674316',
    expectedVariant: 'v1',
  ),
];

void main() {
  group('MGMBucketing golden vectors', () {
    for (final vector in _goldenVectors) {
      test(
          'buckets ${vector.experimentId} / "${vector.userId}" '
          'to ${vector.expectedVariant}', () {
        final bucket = MGMBucketing.bucket(vector.experimentId, vector.userId);
        expect(bucket, BigInt.parse(vector.bucket));

        final variant = MGMBucketing.variantFor(
          vector.experimentId,
          vector.userId,
          vector.variants,
        );
        expect(variant, vector.expectedVariant);
      });
    }
  });

  group('MGMBucketing.bucket', () {
    test('is deterministic', () {
      final a = MGMBucketing.bucket('exp', 'user');
      final b = MGMBucketing.bucket('exp', 'user');
      expect(a, b);
    });

    test('is always non-negative (unsigned 64-bit)', () {
      // Buckets above 2^63 would be negative if folded into a signed int.
      final large = MGMBucketing.bucket(
        '7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71',
        'user_123',
      );
      expect(large > BigInt.two.pow(63), true);
      expect(large.isNegative, false);
      expect(large < BigInt.two.pow(64), true);
    });
  });

  group('MGMBucketing.variantFor', () {
    test('returns null for empty variants', () {
      expect(MGMBucketing.variantFor('exp', 'user', []), null);
    });

    test('returns the only variant when there is one', () {
      expect(MGMBucketing.variantFor('exp', 'user', ['solo']), 'solo');
    });
  });
}
