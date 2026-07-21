import 'dart:math';
import 'dart:typed_data';

import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:pointycastle/export.dart' as pc;

/// Production [BackupCrypto] for the FBC1 container, built entirely on
/// pointycastle (pure Dart, synchronous — no isolates, plugins, or native
/// libsodium dependency; design.md §5).
///
/// It realises the exact port the [Fbc1Codec] framing expects, aligned with the
/// Wave-0 FBC1 reference probe primitives (`tool/probes/fbc1_compatibility`):
///
/// - **Key derivation** is Argon2id v19 (`Argon2BytesGenerator`) over the
///   passphrase and the header's 16-byte salt, using the header-authenticated
///   [Fbc1KdfParameters] (`memoryKiB` → Argon2 memory in KiB, `iterations` →
///   passes, `parallelism` → lanes). Derivation is deterministic for a given
///   passphrase + salt + parameters, and any change to the salt or cost
///   parameters yields a different 32-byte key, so a wrong passphrase can never
///   open an archive.
/// - **Per-frame confidentiality + authentication** is AES-256-GCM. Each frame
///   uses a unique nonce derived from the per-stream random header and a
///   monotonic frame counter, and binds the frame counter, the final flag, and
///   the caller's associated data (which itself binds the header hash, frame
///   type, monotonic index, and declared plaintext length) into the GCM
///   authenticated-data input. Tampered ciphertext/AAD, reordered or truncated
///   frames, and a wrong key all fail authentication — GCM throws and no
///   plaintext is ever returned.
/// - **Hashing** (header hash, per-file content hash, Merkle nodes) is
///   SHA-256, matching the container's 32-byte hash contract, with a genuinely
///   incremental variant so file hashing stays memory-bounded.
///
/// Only this adapter is cipher-specific: the framing, bounds, path rules, and
/// rejection behaviour all live in [Fbc1Codec] regardless of the adapter.
final class PointyCastleBackupCrypto implements BackupCrypto {
  PointyCastleBackupCrypto({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  /// AES-256 key length and the derived-key length (32 bytes).
  @override
  int get keyLength => 32;

  /// AES-GCM appends a 128-bit (16-byte) authentication tag; the ciphertext
  /// body is the same length as the plaintext, so each sealed frame grows by
  /// exactly the tag length.
  @override
  int get frameOverhead => 16;

  /// Per-stream random header from which each frame's 96-bit GCM nonce is
  /// derived. 24 bytes gives a comfortable random prefix; only the first
  /// [_noncePrefixLength] bytes seed the nonce, the remaining 8 carry the
  /// monotonic frame counter.
  @override
  int get streamHeaderLength => 24;

  /// AES-GCM standard nonce length (96 bits).
  static const int _nonceLength = 12;

  /// Bytes of the stream header used as the fixed nonce prefix; the trailing
  /// [_nonceLength] - [_noncePrefixLength] bytes carry the big-endian frame
  /// counter so every frame in a stream gets a distinct nonce.
  static const int _noncePrefixLength = 4;

  @override
  Uint8List deriveKey({
    required List<int> passphrase,
    required List<int> salt,
    required int outputLength,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
  }) {
    final pc.Argon2Parameters params = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      Uint8List.fromList(salt),
      // v19 (0x13) — the reference probe's Argon2id version.
      version: pc.Argon2Parameters.ARGON2_VERSION_13,
      iterations: iterations,
      memory: memoryKiB,
      lanes: parallelism,
      desiredKeyLength: outputLength,
    );
    final pc.Argon2BytesGenerator generator = pc.Argon2BytesGenerator()
      ..init(params);
    final Uint8List out = Uint8List(outputLength);
    generator.deriveKey(Uint8List.fromList(passphrase), 0, out, 0);
    return out;
  }

  @override
  Uint8List hash(List<int> bytes) {
    final pc.SHA256Digest digest = pc.SHA256Digest();
    return digest.process(Uint8List.fromList(bytes));
  }

  @override
  IncrementalHash newIncrementalHash() => _Sha256IncrementalHash();

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
    _requireKey(key);
    return _GcmStreamWriter(
      Uint8List.fromList(key),
      randomBytes(streamHeaderLength),
    );
  }

  @override
  BackupStreamReader openStream(List<int> key, List<int> streamHeader) {
    _requireKey(key);
    return _GcmStreamReader(
      Uint8List.fromList(key),
      Uint8List.fromList(streamHeader),
    );
  }

  @override
  void wipe(Uint8List key) {
    for (int i = 0; i < key.length; i += 1) {
      key[i] = 0;
    }
  }

  void _requireKey(List<int> key) {
    if (key.length != keyLength) {
      throw ArgumentError.value(key.length, 'key', 'must be $keyLength bytes');
    }
  }
}

/// Derives the 96-bit GCM nonce for [counter] from [header]: a fixed random
/// prefix followed by the big-endian frame counter, guaranteeing a distinct
/// nonce per frame within a stream (the derived key is unique per archive salt,
/// so nonces never repeat under a given key).
Uint8List _frameNonce(Uint8List header, int counter) {
  final Uint8List nonce = Uint8List(PointyCastleBackupCrypto._nonceLength);
  nonce.setRange(0, PointyCastleBackupCrypto._noncePrefixLength, header);
  nonce.buffer.asByteData().setUint64(
    PointyCastleBackupCrypto._noncePrefixLength,
    counter,
    Endian.big,
  );
  return nonce;
}

/// Builds the GCM associated-data input: the monotonic frame counter and the
/// final flag are prepended to the caller's [aad] so a frame cannot be
/// reordered or have its finality flipped without failing authentication.
Uint8List _aeadAad(int counter, bool isFinal, List<int> aad) {
  final BytesBuilder builder = BytesBuilder(copy: false)
    ..add(_u64(counter))
    ..addByte(isFinal ? 1 : 0)
    ..add(aad);
  return builder.toBytes();
}

Uint8List _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.big);

pc.GCMBlockCipher _gcm(
  Uint8List key,
  Uint8List nonce,
  Uint8List aad, {
  required bool forEncryption,
}) {
  final pc.GCMBlockCipher cipher = pc.GCMBlockCipher(pc.AESEngine());
  cipher.init(
    forEncryption,
    pc.AEADParameters(pc.KeyParameter(key), 128, nonce, aad),
  );
  return cipher;
}

final class _GcmStreamWriter implements BackupStreamWriter {
  _GcmStreamWriter(this._key, this._header);

  final Uint8List _key;
  final Uint8List _header;
  int _counter = 0;

  @override
  List<int> get header => _header;

  @override
  Uint8List seal(List<int> plaintext, List<int> aad, {required bool isFinal}) {
    final int counter = _counter++;
    final pc.GCMBlockCipher cipher = _gcm(
      _key,
      _frameNonce(_header, counter),
      _aeadAad(counter, isFinal, aad),
      forEncryption: true,
    );
    return cipher.process(Uint8List.fromList(plaintext));
  }
}

final class _GcmStreamReader implements BackupStreamReader {
  _GcmStreamReader(this._key, this._header);

  final Uint8List _key;
  final Uint8List _header;
  int _counter = 0;

  @override
  Uint8List open(List<int> ciphertext, List<int> aad, {required bool isFinal}) {
    final int counter = _counter++;
    final pc.GCMBlockCipher cipher = _gcm(
      _key,
      _frameNonce(_header, counter),
      _aeadAad(counter, isFinal, aad),
      forEncryption: false,
    );
    // Throws pc.InvalidCipherTextException on tag mismatch (tamper, reorder,
    // truncation, or a wrong key); the codec maps that to a fail-closed
    // authentication_failed and never returns plaintext.
    return cipher.process(Uint8List.fromList(ciphertext));
  }
}

/// Incremental SHA-256 backed by pointycastle's streaming digest, so large
/// files can be hashed chunk-by-chunk without buffering.
final class _Sha256IncrementalHash implements IncrementalHash {
  final pc.SHA256Digest _digest = pc.SHA256Digest();

  @override
  void add(List<int> bytes) {
    final Uint8List data = Uint8List.fromList(bytes);
    _digest.update(data, 0, data.length);
  }

  @override
  Uint8List close() {
    final Uint8List out = Uint8List(_digest.digestSize);
    _digest.doFinal(out, 0);
    return out;
  }
}
