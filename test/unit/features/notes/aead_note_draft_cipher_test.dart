import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/application/note_draft_cipher.dart';
import 'package:forge/features/notes/infrastructure/aead_note_draft_cipher.dart';

/// Unit tests for the production synchronous AES-256-GCM draft cipher
/// (R-NOTE-005).
///
/// **Validates: Requirements R-NOTE-005**
void main() {
  // Deterministic 32-byte keys so tests are reproducible.
  Uint8List keyOf(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

  final Uint8List keyA = keyOf(0x11);
  final Uint8List keyB = keyOf(0x22);

  group('AeadNoteDraftCipher construction', () {
    test('rejects a key that is not 32 bytes', () {
      expect(() => AeadNoteDraftCipher(Uint8List(16)), throwsArgumentError);
      expect(() => AeadNoteDraftCipher(Uint8List(33)), throwsArgumentError);
    });
  });

  group('round-trip seal -> open', () {
    final NoteDraftCipher cipher = AeadNoteDraftCipher(keyA);

    test('recovers ascii plaintext', () {
      const String body = 'Hello, this is a draft body with **markdown**.';
      expect(cipher.open(cipher.seal(body)), body);
    });

    test('recovers the empty string', () {
      expect(cipher.open(cipher.seal('')), '');
    });

    test('recovers unicode (emoji, CJK, combining marks)', () {
      const String body = '日本語 draft — café ☕ 😀 नमस्ते \u{1F600}\u0301';
      expect(cipher.open(cipher.seal(body)), body);
    });

    test('recovers a large string', () {
      final String body = List<String>.generate(
        20000,
        (int i) => 'line-$i-λ ',
      ).join();
      expect(cipher.open(cipher.seal(body)), body);
    });
  });

  group('confidentiality', () {
    final NoteDraftCipher cipher = AeadNoteDraftCipher(keyA);

    test('sealed form is neither the plaintext nor legibly contains it', () {
      const String body = 'super secret note body content';
      final String sealed = cipher.seal(body);

      expect(sealed, isNot(equals(body)));
      expect(sealed.contains(body), isFalse);
      expect(sealed.startsWith('fnd1:'), isTrue);

      // The decoded envelope bytes must not contain the utf8 plaintext.
      final Uint8List envelope = base64.decode(
        sealed.substring('fnd1:'.length),
      );
      final List<int> plainBytes = utf8.encode(body);
      expect(
        _containsSubsequence(envelope, plainBytes),
        isFalse,
        reason: 'ciphertext leaks plaintext bytes',
      );
    });

    test('two seals of the same plaintext differ (fresh nonce)', () {
      const String body = 'identical plaintext';
      final String first = cipher.seal(body);
      final String second = cipher.seal(body);
      expect(first, isNot(equals(second)));
      // Both still decrypt back to the same plaintext.
      expect(cipher.open(first), body);
      expect(cipher.open(second), body);
    });
  });

  group('authentication failures throw and never leak plaintext', () {
    final NoteDraftCipher cipher = AeadNoteDraftCipher(keyA);

    test('prefix mismatch throws FormatException', () {
      final String sealed = cipher.seal('body');
      final String wrongPrefix = sealed.replaceFirst('fnd1:', 'xxxx:');
      expect(() => cipher.open(wrongPrefix), throwsFormatException);
    });

    test('missing prefix throws FormatException', () {
      expect(() => cipher.open('not-an-envelope'), throwsFormatException);
    });

    test('non-base64 body throws FormatException', () {
      expect(() => cipher.open('fnd1:@@@not base64@@@'), throwsFormatException);
    });

    test('truncated body throws FormatException', () {
      // A prefix over a couple of bytes: shorter than nonce + tag.
      expect(
        () => cipher.open('fnd1:${base64.encode(<int>[1, 2, 3])}'),
        throwsFormatException,
      );
    });

    test('tampered envelope body (flipped byte) throws and never returns '
        'plaintext', () {
      const String body = 'authentic draft body';
      final String sealed = cipher.seal(body);
      final Uint8List envelope = base64.decode(
        sealed.substring('fnd1:'.length),
      );
      // Flip a byte inside the ciphertext region (after the 12-byte nonce).
      envelope[envelope.length - 1] ^= 0x01;
      final String tampered = 'fnd1:${base64.encode(envelope)}';
      expect(
        () => cipher.open(tampered),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
    });

    test('opening with a different key throws (authentication)', () {
      final NoteDraftCipher sealer = AeadNoteDraftCipher(keyA);
      final NoteDraftCipher opener = AeadNoteDraftCipher(keyB);
      final String sealed = sealer.seal('body only key A can open');
      expect(
        () => opener.open(sealed),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
    });
  });
}

/// Returns true if [needle] appears as a contiguous subsequence of [haystack].
bool _containsSubsequence(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) {
    return true;
  }
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    bool match = true;
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}
