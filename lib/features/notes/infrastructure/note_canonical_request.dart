import 'dart:convert';

/// Canonical request encoding and hashing for note command receipts and the
/// note content hash (R-GEN-005, R-NOTE-004).
///
/// The canonical payload is deterministic JSON with object keys sorted, so the
/// same logical request always produces the same bytes and therefore the same
/// [stableHash]. The hash is a 64-bit FNV-1a digest rendered as zero-padded
/// hex: a deduplication/content fingerprint, not a security primitive, which
/// keeps the production `lib` free of crypto dependencies (mirrors the tasks
/// feature's own copy so notes never import another feature's infrastructure).
abstract final class NoteCanonicalRequest {
  static String encode(Map<String, Object?> payload) =>
      jsonEncode(_canonicalize(payload));

  static String stableHash(String value) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    int hash = fnvOffset;
    final List<int> bytes = utf8.encode(value);
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
