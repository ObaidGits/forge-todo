import 'dart:convert';

/// Canonical request encoding and hashing for durable reminder command
/// receipts (R-GEN-005).
///
/// Deterministic JSON with object keys sorted, so the same logical request
/// always produces the same bytes and therefore the same [stableHash]. This is
/// a feature-local copy so notifications never imports another feature's
/// infrastructure (architecture fitness rule, design §16).
abstract final class ReminderCanonicalRequest {
  static String encode(Map<String, Object?> payload) =>
      jsonEncode(_canonicalize(payload));

  static String stableHash(String canonicalPayload) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    int hash = fnvOffset;
    final List<int> bytes = utf8.encode(canonicalPayload);
    for (final int b in bytes) {
      hash = (hash ^ b) * fnvPrime;
      hash &= 0xffffffffffffffff;
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
