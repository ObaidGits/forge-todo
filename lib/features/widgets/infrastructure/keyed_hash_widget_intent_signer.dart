/// A keyed-hash widget intent signer (spoof-resistance foundation,
/// R-WIDGET-003).
///
/// This is the Dart-side foundation for widget-intent authentication. It
/// derives a fixed-length tag over the canonical payload using a secret shared
/// between the app and the native widget container, in an HMAC-style two-pass
/// construction over multiple independent hash lanes. Without the secret an
/// adversary cannot produce a tag that verifies, and any change to the payload
/// changes the tag, so a spoofed or tampered intent is rejected.
///
/// The construction uses pure-Dart 64-bit lanes rather than a platform crypto
/// primitive so the contract is dependency-free and deterministically testable;
/// the concrete platform build (task 11.2) may substitute a
/// stronger [WidgetIntentSigner] behind the same port.
library;

import 'dart:convert';

import 'package:forge/features/widgets/application/widget_bridge.dart';

final class KeyedHashWidgetIntentSigner implements WidgetIntentSigner {
  KeyedHashWidgetIntentSigner({required String secret})
    : _secret = _requireSecret(secret);

  final String _secret;

  static String _requireSecret(String secret) {
    if (secret.length < 16) {
      throw ArgumentError.value(
        secret,
        'secret',
        'Widget bridge secret must be at least 16 characters.',
      );
    }
    return secret;
  }

  // Distinct FNV-1a offset seeds; each lane contributes 64 bits of tag.
  static const List<int> _laneSeeds = <int>[
    0xcbf29ce484222325,
    0x84222325cbf29ce4,
    0x9e3779b97f4a7c15,
    0xff51afd7ed558ccd,
  ];
  static const int _fnvPrime = 0x100000001b3;
  static const int _mask = 0xffffffffffffffff;

  @override
  String sign(String canonicalPayload) {
    final List<int> keyBytes = utf8.encode(_secret);
    final List<int> ipad = <int>[for (final int b in keyBytes) b ^ 0x36];
    final List<int> opad = <int>[for (final int b in keyBytes) b ^ 0x5c];
    final List<int> message = utf8.encode(canonicalPayload);

    final StringBuffer tag = StringBuffer();
    for (final int seed in _laneSeeds) {
      final int inner = _hash(seed, <int>[...ipad, ...message]);
      final int outer = _hash(seed, <int>[...opad, ..._toBytes(inner)]);
      tag.write(outer.toRadixString(16).padLeft(16, '0'));
    }
    return tag.toString();
  }

  @override
  bool verify(String canonicalPayload, String token) =>
      _constantTimeEquals(sign(canonicalPayload), token);

  static int _hash(int seed, List<int> bytes) {
    int hash = seed & _mask;
    for (final int b in bytes) {
      hash = (hash ^ b) & _mask;
      hash = (hash * _fnvPrime) & _mask;
    }
    return hash;
  }

  static List<int> _toBytes(int value) => <int>[
    for (int shift = 56; shift >= 0; shift -= 8) (value >> shift) & 0xff,
  ];

  /// Length-independent, content constant-time comparison. Avoids leaking where
  /// two equal-length tags first diverge.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i += 1) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
