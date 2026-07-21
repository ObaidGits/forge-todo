import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/secure_key_store.dart';

/// A [KeyVault] that custodies the 32-byte device database key in an OS-backed
/// secret store ([SecureKeyStore]) under a fixed key name.
///
/// ## Why this exists
/// [LocalFileKeyVault] persists the key in a chmod-600 file. That protects the
/// key at rest against other users but not against anything that can read the
/// owner's files. When the platform exposes a hardware/OS-guarded secret
/// service (libsecret, Keychain, DPAPI, Keystore) the key should live there
/// instead. This vault is that hardened custodian; the composition root selects
/// it when the secret service is available and consistent with the current
/// ciphertext state, and falls back to [LocalFileKeyVault] otherwise.
///
/// ## Async-init tolerance
/// Secret-store reads/writes are asynchronous, but the [KeyVault.state] getter
/// is synchronous. This vault therefore caches its last-known lifecycle state,
/// which [ensureProvisioned] and [release] refine as they observe the store.
/// The cached [state] is only ever consumed as a diagnostic label by the
/// runtime; the authoritative fail-closed decision is driven by [release]
/// throwing and by [encryptedStoreExists] (a synchronous ciphertext probe).
///
/// ## Security spine (R-SEC-001) — preserved
/// A replacement key is minted ONLY on a provably-fresh install: no stored key
/// AND no existing ciphertext. If ciphertext exists but no key can be retrieved
/// (absent, malformed, wrong length, or the store is unavailable), this vault
/// NEVER mints a new key — [release] throws [KeyReleaseUnavailable] and reports
/// [KeyVaultState.recoveryRequired] so the runtime routes to non-destructive
/// Recovery Mode. Existing encrypted data can only be opened or recovered.
///
/// The key is generated with a cryptographically secure RNG ([Random.secure])
/// and stored base64-encoded (the [SecureKeyStore] contract carries strings).
final class SecureStorageKeyVault implements KeyVault {
  SecureStorageKeyVault({
    required this.store,
    required this.ciphertextExists,
    Random? random,
    this.keyName = defaultKeyName,
    this.keyLengthBytes = 32,
  }) : _random = random ?? Random.secure();

  /// The fixed secret-store entry name for the device key. Versioned so a
  /// future key-format change can migrate under a new name without colliding.
  static const String defaultKeyName = 'forge.device.key.v1';

  /// The OS secret store backing this vault.
  final SecureKeyStore store;

  /// Synchronous probe for whether any encrypted store already depends on this
  /// key (the active-generation pointer or a generation database file exists).
  /// Drives the no-replacement-key invariant.
  final bool Function() ciphertextExists;

  /// The entry name under which the key is stored.
  final String keyName;

  /// Expected raw key length in bytes (256-bit).
  final int keyLengthBytes;

  final Random _random;

  // Last-known lifecycle state. Refined by [ensureProvisioned]/[release]. Its
  // conservative initial value reflects the ciphertext probe: existing
  // ciphertext with an as-yet-unobserved key is treated as recovery-pending.
  KeyVaultState _state = KeyVaultState.creating;

  @override
  KeyVaultState get state => _state;

  @override
  bool get encryptedStoreExists => ciphertextExists();

  /// Mints and persists a fresh key ONLY when the install is provably fresh.
  ///
  /// Idempotent: returns immediately if a key already exists. Refuses to mint
  /// when ciphertext exists without a key (R-SEC-001) so the subsequent
  /// [release] fails closed into Recovery Mode.
  ///
  /// Throws [SecureKeyStoreUnavailable] when the secret service cannot be
  /// reached, so the composition root can fall back to the file vault. It never
  /// swallows unavailability as "fresh".
  Future<void> ensureProvisioned() async {
    final String? existing = await store.read(keyName);
    if (existing != null) {
      _state = KeyVaultState.available;
      return;
    }
    // No stored key.
    if (ciphertextExists()) {
      // Ciphertext with no key: never mint a replacement. Leave state so
      // release() routes to Recovery Mode.
      _state = KeyVaultState.recoveryRequired;
      return;
    }
    // Provably fresh install: mint a CSPRNG 256-bit key and store it securely.
    final Uint8List key = _generateKey();
    try {
      await store.write(keyName, base64Encode(key));
    } finally {
      key.fillRange(0, key.length, 0);
    }
    _state = KeyVaultState.available;
  }

  @override
  Future<KeyLease> release() async {
    final String? stored;
    try {
      stored = await store.read(keyName);
    } on SecureKeyStoreUnavailable catch (error) {
      // Secret service unreadable. Fail closed: existing ciphertext is Recovery
      // Mode, never a mint. A fresh store simply has no key to release.
      _state = ciphertextExists()
          ? KeyVaultState.recoveryRequired
          : KeyVaultState.absent;
      throw KeyReleaseUnavailable(
        _state,
        'Secure storage is unavailable: ${error.message}',
      );
    }

    if (stored == null) {
      _state = ciphertextExists()
          ? KeyVaultState.recoveryRequired
          : KeyVaultState.absent;
      throw KeyReleaseUnavailable(
        _state,
        'No device key is available in secure storage.',
      );
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(stored);
    } on FormatException {
      // A malformed stored value over existing ciphertext is unrecoverable; do
      // not mint a replacement.
      _state = KeyVaultState.recoveryRequired;
      throw const KeyReleaseUnavailable(
        KeyVaultState.recoveryRequired,
        'Stored device key is malformed.',
      );
    }

    if (bytes.length != keyLengthBytes) {
      bytes.fillRange(0, bytes.length, 0);
      _state = KeyVaultState.recoveryRequired;
      throw const KeyReleaseUnavailable(
        KeyVaultState.recoveryRequired,
        'Stored device key has an unexpected length.',
      );
    }

    _state = KeyVaultState.available;
    return _SecureKeyLease(bytes);
  }

  Uint8List _generateKey() {
    final Uint8List key = Uint8List(keyLengthBytes);
    for (int i = 0; i < keyLengthBytes; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }
}

/// A defensive-copy lease that zeroizes its buffer on dispose.
final class _SecureKeyLease implements KeyLease {
  _SecureKeyLease(this._bytes);

  final Uint8List _bytes;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  Uint8List copyBytes() {
    if (_disposed) {
      throw StateError('Key lease has been disposed.');
    }
    return Uint8List.fromList(_bytes);
  }

  @override
  Future<void> dispose() async {
    _bytes.fillRange(0, _bytes.length, 0);
    _disposed = true;
  }
}
