import 'dart:typed_data';

/// Cryptographic boundary for managed attachments (R-SEC-002).
///
/// Each attachment is encrypted at rest with its own random data-encryption key
/// (DEK). The DEK is wrapped under a key-encryption key (KEK) — the device
/// profile key released by the [KeyVault] — so the database and the encrypted
/// files are useless without the device key. Backup rewraps the DEK under an
/// independent backup key or stream re-encrypts content; the device KEK is
/// never exported.
///
/// The concrete authenticated-cipher adapter (libsodium/XChaCha20-Poly1305) is
/// kept strictly behind this port per ADR-0001, exactly like the
/// `EncryptedStore`/`BackupCrypto` boundaries: the composition root wires the
/// native adapter once accepted, while tests wire a deterministic in-process
/// authenticated adapter. No domain/application code depends on a cipher API.
abstract interface class AttachmentCrypto {
  /// Versioned content/DEK cipher identifier stored with each attachment.
  String get cipherVersion;

  /// Length in bytes of a DEK produced by [newDek].
  int get dekLength;

  /// Generates a fresh cryptographically random per-file DEK.
  Uint8List newDek();

  /// Wraps [dek] under [kek], returning an opaque, authenticated envelope safe
  /// to persist in metadata. Never returns raw key bytes.
  String wrapDek({required List<int> dek, required List<int> kek});

  /// Unwraps an envelope produced by [wrapDek]. Throws
  /// [AttachmentCryptoAuthError] when the envelope is inauthentic or the wrong
  /// KEK is supplied.
  Uint8List unwrapDek({required String wrappedDek, required List<int> kek});

  /// Encrypts [plaintext] under [dek] into authenticated ciphertext.
  Uint8List sealContent({required List<int> plaintext, required List<int> dek});

  /// Decrypts ciphertext produced by [sealContent]. Throws
  /// [AttachmentCryptoAuthError] when the ciphertext is inauthentic.
  Uint8List openContent({
    required List<int> ciphertext,
    required List<int> dek,
  });

  /// Lowercase-hex SHA-256 of [plaintext], used to pin content (R-NOTE-006).
  String contentHashHex(List<int> plaintext);

  /// Best-effort zeroization of transient key material.
  void wipe(Uint8List bytes);
}

/// Raised when authenticated decryption/unwrapping fails. Fail-closed: content
/// is never returned when authentication fails.
final class AttachmentCryptoAuthError implements Exception {
  const AttachmentCryptoAuthError([this.detail]);

  final String? detail;

  @override
  String toString() =>
      'AttachmentCryptoAuthError(${detail ?? 'authentication failed'})';
}
