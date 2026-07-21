import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';

/// In-process authenticated [AttachmentCrypto] for tests.
///
/// Production wires a native XChaCha20-Poly1305 adapter (ADR-0001). This test
/// adapter provides *real* authenticated cryptography using an HMAC-SHA256
/// keystream + Encrypt-then-MAC tag, so:
///
/// * a wrong DEK or KEK fails authentication (`AttachmentCryptoAuthError`),
///   giving genuine key-portability guarantees for the backup rewrap tests;
/// * tampered ciphertext fails authentication;
/// * content hashing is genuine SHA-256.
final class FakeAttachmentCrypto implements AttachmentCrypto {
  FakeAttachmentCrypto({Random? random}) : _random = random ?? Random(20250718);

  final Random _random;

  @override
  String get cipherVersion => 'fake-attach-aead-v1';

  @override
  int get dekLength => 32;

  @override
  Uint8List newDek() {
    final Uint8List dek = Uint8List(dekLength);
    for (int i = 0; i < dek.length; i += 1) {
      dek[i] = _random.nextInt(256);
    }
    return dek;
  }

  @override
  String wrapDek({required List<int> dek, required List<int> kek}) {
    final Uint8List sealed = _seal(Uint8List.fromList(dek), kek, _wrapContext);
    return base64Encode(sealed);
  }

  @override
  Uint8List unwrapDek({required String wrappedDek, required List<int> kek}) {
    final Uint8List sealed = base64Decode(wrappedDek);
    return _open(sealed, kek, _wrapContext);
  }

  @override
  Uint8List sealContent({
    required List<int> plaintext,
    required List<int> dek,
  }) => _seal(Uint8List.fromList(plaintext), dek, _contentContext);

  @override
  Uint8List openContent({
    required List<int> ciphertext,
    required List<int> dek,
  }) => _open(Uint8List.fromList(ciphertext), dek, _contentContext);

  @override
  String contentHashHex(List<int> plaintext) =>
      sha256.convert(plaintext).toString();

  @override
  void wipe(Uint8List bytes) {
    for (int i = 0; i < bytes.length; i += 1) {
      bytes[i] = 0;
    }
  }

  static const List<int> _wrapContext = <int>[0x77, 0x72]; // 'wr'
  static const List<int> _contentContext = <int>[0x63, 0x6e]; // 'cn'

  Uint8List _seal(Uint8List plaintext, List<int> key, List<int> context) {
    final Uint8List ks = _keystream(key, context, plaintext.length);
    final Uint8List body = Uint8List(plaintext.length);
    for (int i = 0; i < plaintext.length; i += 1) {
      body[i] = plaintext[i] ^ ks[i];
    }
    final List<int> tag = Hmac(sha256, <int>[
      ...key,
      ...context,
      0x6d,
    ]).convert(body).bytes;
    return Uint8List.fromList(<int>[...body, ...tag]);
  }

  Uint8List _open(Uint8List sealed, List<int> key, List<int> context) {
    if (sealed.length < 32) {
      throw const AttachmentCryptoAuthError('ciphertext too short');
    }
    final int bodyLength = sealed.length - 32;
    final Uint8List body = Uint8List.sublistView(sealed, 0, bodyLength);
    final List<int> tag = sealed.sublist(bodyLength);
    final List<int> expected = Hmac(sha256, <int>[
      ...key,
      ...context,
      0x6d,
    ]).convert(body).bytes;
    if (!_constantTimeEqual(expected, tag)) {
      throw const AttachmentCryptoAuthError('authentication tag mismatch');
    }
    final Uint8List ks = _keystream(key, context, bodyLength);
    final Uint8List plaintext = Uint8List(bodyLength);
    for (int i = 0; i < bodyLength; i += 1) {
      plaintext[i] = body[i] ^ ks[i];
    }
    return plaintext;
  }

  Uint8List _keystream(List<int> key, List<int> context, int length) {
    final Hmac mac = Hmac(sha256, <int>[...key, ...context, 0x6b]);
    final Uint8List out = Uint8List(length);
    int produced = 0;
    int block = 0;
    while (produced < length) {
      final List<int> chunk = mac.convert(<int>[block]).bytes;
      for (int i = 0; i < chunk.length && produced < length; i += 1) {
        out[produced++] = chunk[i];
      }
      block += 1;
    }
    return out;
  }

  bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i += 1) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
