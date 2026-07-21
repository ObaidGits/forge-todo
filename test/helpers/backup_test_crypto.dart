import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';

/// In-process [BackupCrypto] for backup tests.
///
/// Production wires the native libsodium/Argon2id adapter validated by the
/// Wave-0 FBC1 reference probe. This adapter provides *real* authenticated
/// cryptography using HMAC-SHA256 so export/validate/restore tests exercise
/// genuine integrity guarantees (tamper, truncation, reorder, and wrong-key
/// all fail authentication) without a native dependency:
///
/// - key derivation is PBKDF2/HMAC-SHA256 over the passphrase, salt, and the
///   Argon2id cost parameters (so out-of-policy parameters yield a different
///   key, exactly like the authenticated header binding);
/// - each frame is encrypted with an HMAC-SHA256 keystream and authenticated
///   with an Encrypt-then-MAC tag whose input chains a per-stream monotonic
///   counter, the final flag, and the caller's associated data, so any
///   reordered, duplicated, truncated, or tampered frame fails to open.
final class BackupTestCrypto implements BackupCrypto {
  BackupTestCrypto({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  @override
  int get keyLength => 32;

  @override
  int get frameOverhead => 32; // HMAC-SHA256 tag.

  @override
  int get streamHeaderLength => 24;

  @override
  Uint8List deriveKey({
    required List<int> passphrase,
    required List<int> salt,
    required int outputLength,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
  }) {
    // Bind the Argon2id cost parameters into the salt so different parameters
    // derive different keys, matching the authenticated header contract.
    final List<int> boundSalt = <int>[
      ...salt,
      ..._u32(memoryKiB),
      ..._u32(iterations),
      ..._u32(parallelism),
    ];
    return _pbkdf2(
      password: passphrase,
      salt: boundSalt,
      iterations: iterations < 1 ? 1 : iterations,
      length: outputLength,
    );
  }

  @override
  Uint8List hash(List<int> bytes) =>
      Uint8List.fromList(sha256.convert(bytes).bytes);

  @override
  IncrementalHash newIncrementalHash() => _IncrementalSha256();

  @override
  Uint8List randomBytes(int length) {
    final Uint8List out = Uint8List(length);
    for (int i = 0; i < length; i += 1) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  @override
  BackupStreamWriter beginStream(List<int> key) {
    final Uint8List header = randomBytes(streamHeaderLength);
    return _StreamWriter(Uint8List.fromList(key), header);
  }

  @override
  BackupStreamReader openStream(List<int> key, List<int> streamHeader) =>
      _StreamReader(Uint8List.fromList(key), Uint8List.fromList(streamHeader));

  @override
  void wipe(Uint8List key) {
    for (int i = 0; i < key.length; i += 1) {
      key[i] = 0;
    }
  }
}

Uint8List _pbkdf2({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int length,
}) {
  final Hmac mac = Hmac(sha256, password);
  final List<int> out = <int>[];
  int block = 1;
  while (out.length < length) {
    final List<int> salted = <int>[...salt, ..._u32(block)];
    List<int> u = mac.convert(salted).bytes;
    final List<int> f = List<int>.of(u);
    for (int i = 1; i < iterations; i += 1) {
      u = mac.convert(u).bytes;
      for (int j = 0; j < f.length; j += 1) {
        f[j] ^= u[j];
      }
    }
    out.addAll(f);
    block += 1;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

Uint8List _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.big);

Uint8List _keystream(Uint8List key, Uint8List header, int counter, int length) {
  final Hmac mac = Hmac(sha256, <int>[...key, ...header, 0x6b, 0x73]); // 'ks'
  final Uint8List out = Uint8List(length);
  int produced = 0;
  int blockIndex = 0;
  while (produced < length) {
    final List<int> block = mac.convert(<int>[
      ..._u64(counter),
      ..._u32(blockIndex),
    ]).bytes;
    for (int i = 0; i < block.length && produced < length; i += 1) {
      out[produced++] = block[i];
    }
    blockIndex += 1;
  }
  return out;
}

Uint8List _tag(
  Uint8List key,
  Uint8List header,
  int counter,
  bool isFinal,
  List<int> aad,
  List<int> cipherBody,
) {
  final Hmac mac = Hmac(sha256, <int>[...key, ...header, 0x6d, 0x61]); // 'ma'
  return Uint8List.fromList(
    mac.convert(<int>[
      ..._u64(counter),
      isFinal ? 1 : 0,
      ..._u32(aad.length),
      ...aad,
      ..._u32(cipherBody.length),
      ...cipherBody,
    ]).bytes,
  );
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

final class _StreamWriter implements BackupStreamWriter {
  _StreamWriter(this._key, this._header);

  final Uint8List _key;
  final Uint8List _header;
  int _counter = 0;

  @override
  List<int> get header => _header;

  @override
  Uint8List seal(List<int> plaintext, List<int> aad, {required bool isFinal}) {
    final int counter = _counter++;
    final Uint8List ks = _keystream(_key, _header, counter, plaintext.length);
    final Uint8List body = Uint8List(plaintext.length);
    for (int i = 0; i < plaintext.length; i += 1) {
      body[i] = plaintext[i] ^ ks[i];
    }
    final Uint8List tag = _tag(_key, _header, counter, isFinal, aad, body);
    return Uint8List.fromList(<int>[...body, ...tag]);
  }
}

final class _StreamReader implements BackupStreamReader {
  _StreamReader(this._key, this._header);

  final Uint8List _key;
  final Uint8List _header;
  int _counter = 0;

  @override
  Uint8List open(List<int> ciphertext, List<int> aad, {required bool isFinal}) {
    if (ciphertext.length < 32) {
      throw const Fbc1FormatException('cipher_too_short', 0);
    }
    final int bodyLength = ciphertext.length - 32;
    final Uint8List body = Uint8List.fromList(
      ciphertext.sublist(0, bodyLength),
    );
    final List<int> tag = ciphertext.sublist(bodyLength);
    final int counter = _counter++;
    final Uint8List expected = _tag(_key, _header, counter, isFinal, aad, body);
    if (!_constantTimeEqual(expected, tag)) {
      throw const Fbc1FormatException('auth_tag_mismatch', 0);
    }
    final Uint8List ks = _keystream(_key, _header, counter, bodyLength);
    final Uint8List plaintext = Uint8List(bodyLength);
    for (int i = 0; i < bodyLength; i += 1) {
      plaintext[i] = body[i] ^ ks[i];
    }
    return plaintext;
  }
}

final class _IncrementalSha256 implements IncrementalHash {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  @override
  void add(List<int> bytes) => _buffer.add(bytes);

  @override
  Uint8List close() =>
      Uint8List.fromList(sha256.convert(_buffer.takeBytes()).bytes);
}
