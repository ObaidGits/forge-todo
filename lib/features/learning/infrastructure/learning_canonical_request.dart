import 'dart:convert';

/// Canonical request encoding and hashing for learning durable command receipts
/// (R-GEN-005).
///
/// The canonical payload is deterministic JSON with object keys sorted, so the
/// same logical request always produces the same bytes and therefore the same
/// [stableHash]. A different request under the same command id produces a
/// different hash and is rejected by the command bus. The hash is a 64-bit
/// FNV-1a digest rendered as zero-padded hex — a deduplication fingerprint, not
/// a security primitive. Each feature owns its own canonical-request helper so
/// infrastructure boundaries stay independent.
abstract final class LearningCanonicalRequest {
  static String encode(Map<String, Object?> payload) =>
      jsonEncode(_canonicalize(payload));

  static String stableHash(String canonicalPayload) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    int hash = fnvOffset;
    final List<int> bytes = utf8.encode(canonicalPayload);
    for (final int b in bytes) {
      hash = (hash ^ b) * fnvPrime;
      hash &= 0xffffffffffffffff; // wrap to 64 bits
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final List<String> keys =
          value.keys.map((Object? k) => k as String).toList()..sort();
      return <String, Object?>{
        for (final String key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }
}
