import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Deterministic on-device bucketing for local experiment enrollment.
///
/// The algorithm is shared across MostlyGoodMetrics SDKs so a given
/// (experiment, user) pair always resolves to the same variant.
class MGMBucketing {
  MGMBucketing._();

  /// Computes the bucket for a user in an experiment.
  ///
  /// The bucket is the first 8 bytes of
  /// `SHA-256(utf8("<experimentId>:<userId>"))` interpreted as an unsigned
  /// big-endian 64-bit integer.
  ///
  /// Returned as a [BigInt]: Dart ints are 64-bit *signed*, so folding the
  /// bytes into an int would flip large buckets negative and corrupt the
  /// modulo below.
  static BigInt bucket(String experimentId, String userId) {
    final digest = sha256.convert(utf8.encode('$experimentId:$userId'));
    var value = BigInt.zero;
    for (final byte in digest.bytes.take(8)) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  /// Picks the variant for a user: `variants[bucket % variants.length]`.
  ///
  /// Returns null when [variants] is empty.
  static String? variantFor(
    String experimentId,
    String userId,
    List<String> variants,
  ) {
    if (variants.isEmpty) return null;
    final index = bucket(experimentId, userId) % BigInt.from(variants.length);
    return variants[index.toInt()];
  }
}
