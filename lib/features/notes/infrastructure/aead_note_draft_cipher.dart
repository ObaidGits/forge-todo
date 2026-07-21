import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:forge/features/notes/application/note_draft_cipher.dart';
import 'package:pointycastle/export.dart';

/// Production [NoteDraftCipher]: a synchronous AES-256-GCM AEAD over a 32-byte
/// key (R-NOTE-005).
///
/// ## Why synchronous / pure Dart
/// [seal]/[open] run inside a database write transaction, so they MUST be
/// synchronous and free of plugin/isolate/Future calls (design.md §5). This is
/// why the implementation uses `pointycastle` (pure-Dart, synchronous) rather
/// than the async `cryptography` package.
///
/// ## Envelope format
/// The sealed string is a domain/version-prefixed, compact envelope:
///
/// ```text
/// fnd1:<base64( nonce[12] || ciphertext || tag[16] )>
/// ```
///
/// * `fnd1:` is a fixed version prefix; [open] rejects anything else.
/// * A fresh cryptographically-random 96-bit nonce is generated per [seal], so
///   two seals of the same plaintext differ.
/// * AES-256-GCM authenticates the ciphertext; [open] throws (and never returns
///   plaintext) on any prefix mismatch, malformed body, or authentication
///   failure (wrong key / tampered envelope).
///
/// The key lives only in this instance's memory; it is never persisted.
final class AeadNoteDraftCipher implements NoteDraftCipher {
  /// Constructs a cipher over a 32-byte (256-bit) [key].
  ///
  /// A defensive copy of [key] is retained; the caller may zero its own buffer
  /// (e.g. the KeyVault lease) immediately after construction.
  AeadNoteDraftCipher(Uint8List key)
    : _key = _validatedKey(key),
      _random = _seededRandom();

  /// The fixed domain/version prefix on every sealed envelope.
  static const String _prefix = 'fnd1:';

  /// AES-256 requires a 32-byte key.
  static const int _keyLengthBytes = 32;

  /// GCM standard nonce length (96 bits).
  static const int _nonceLengthBytes = 12;

  /// GCM authentication tag length (128 bits).
  static const int _macSizeBits = 128;
  static const int _tagLengthBytes = _macSizeBits ~/ 8;

  final KeyParameter _key;
  final SecureRandom _random;
  static final Uint8List _emptyAad = Uint8List(0);

  @override
  String seal(String plaintext) {
    final Uint8List nonce = _random.nextBytes(_nonceLengthBytes);
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(_key, _macSizeBits, nonce, _emptyAad));
    final Uint8List plainBytes = Uint8List.fromList(utf8.encode(plaintext));
    final Uint8List sealedBody = cipher.process(plainBytes);

    final Uint8List envelope = Uint8List(nonce.length + sealedBody.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealedBody.length, sealedBody);
    return '$_prefix${base64.encode(envelope)}';
  }

  @override
  String open(String sealed) {
    if (!sealed.startsWith(_prefix)) {
      throw const FormatException('Not a sealed draft envelope.');
    }
    final Uint8List raw;
    try {
      raw = base64.decode(sealed.substring(_prefix.length));
    } on FormatException {
      throw const FormatException('Draft envelope body is not valid base64.');
    }
    // Must hold at least the nonce plus a full authentication tag.
    if (raw.length < _nonceLengthBytes + _tagLengthBytes) {
      throw const FormatException('Draft envelope is too short.');
    }
    final Uint8List nonce = Uint8List.sublistView(raw, 0, _nonceLengthBytes);
    final Uint8List sealedBody = Uint8List.sublistView(raw, _nonceLengthBytes);
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(_key, _macSizeBits, nonce, _emptyAad));
    final Uint8List plainBytes;
    try {
      plainBytes = cipher.process(sealedBody);
    } on InvalidCipherTextException catch (error) {
      // Authentication failed: wrong key or tampered envelope. Never return
      // partial/plaintext output.
      throw StateError('Draft envelope failed authentication: $error');
    }
    return utf8.decode(plainBytes);
  }

  static KeyParameter _validatedKey(Uint8List key) {
    if (key.length != _keyLengthBytes) {
      throw ArgumentError.value(
        key.length,
        'key.length',
        'AES-256 draft cipher requires a $_keyLengthBytes-byte key.',
      );
    }
    return KeyParameter(Uint8List.fromList(key));
  }

  /// A Fortuna CSPRNG seeded from [Random.secure] entropy for fresh per-seal
  /// nonces.
  static SecureRandom _seededRandom() {
    final FortunaRandom random = FortunaRandom();
    final Random seedSource = Random.secure();
    final Uint8List seed = Uint8List(32);
    for (int i = 0; i < seed.length; i++) {
      seed[i] = seedSource.nextInt(256);
    }
    random.seed(KeyParameter(seed));
    return random;
  }
}
