import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:forge/core/security/key_vault.dart';

/// A local-only, device-scoped [KeyVault] that persists a random 256-bit
/// database key in a permission-restricted file under the app-support tree.
///
/// ## Why this exists
/// The full production custodian is [KeyVaultMachine] wired with platform
/// secure-store, biometric, and Argon2id passphrase ports. On a headless Linux
/// desktop without a usable secret service those ports are unavailable, so this
/// adapter provides a correct, local-only key custodian for a single-device
/// install. It is intentionally small; swapping in the platform-backed
/// [MachineBackedKeyVault] later is a composition-root change only.
///
/// ## Security spine (R-SEC-001) — preserved
/// A replacement key is minted ONLY when the install is provably fresh: the key
/// file is absent AND no ciphertext (pointer or generation database) exists.
/// If ciphertext exists but the key is missing/unreadable, this vault NEVER
/// mints a new key — [release] throws [KeyReleaseUnavailable] and reports
/// [KeyVaultState.recoveryRequired] so the runtime routes to non-destructive
/// Recovery Mode. Existing encrypted data can only be opened or recovered,
/// never silently reset.
///
/// The key is generated with a cryptographically secure RNG ([Random.secure])
/// and stored as raw bytes in a file the app creates inside its own private
/// support directory. On POSIX the file mode is tightened to owner-only.
final class LocalFileKeyVault implements KeyVault {
  LocalFileKeyVault({
    required this.keyFile,
    required this.ciphertextExists,
    Random? random,
    this.keyLengthBytes = 32,
  }) : _random = random ?? Random.secure();

  /// The file that stores the raw device key.
  final io.File keyFile;

  /// Probe for whether any encrypted store already depends on this key (the
  /// active-generation pointer or a generation database file exists). Used to
  /// enforce the no-replacement-key invariant.
  final bool Function() ciphertextExists;

  final Random _random;
  final int keyLengthBytes;

  @override
  KeyVaultState get state {
    if (keyFile.existsSync()) {
      return KeyVaultState.available;
    }
    // No key material. If ciphertext depends on a key, this is unrecoverable
    // and must not mint a replacement.
    return ciphertextExists()
        ? KeyVaultState.recoveryRequired
        : KeyVaultState.absent;
  }

  @override
  bool get encryptedStoreExists => ciphertextExists();

  /// Mints and persists a fresh key ONLY when the install is provably fresh.
  ///
  /// Idempotent: returns immediately if a key already exists. Refuses to mint
  /// when ciphertext exists without a key (R-SEC-001) so the subsequent
  /// [release] fails closed into Recovery Mode.
  Future<void> ensureProvisioned() async {
    if (keyFile.existsSync()) {
      return;
    }
    if (ciphertextExists()) {
      // Ciphertext with no key: never mint a replacement. Leave it so release()
      // routes to Recovery Mode.
      return;
    }
    final Uint8List key = _generateKey();
    await keyFile.parent.create(recursive: true);
    await keyFile.writeAsBytes(key, flush: true);
    _restrictPermissions(keyFile);
    key.fillRange(0, key.length, 0);
  }

  @override
  Future<KeyLease> release() async {
    if (!keyFile.existsSync()) {
      // No key. A fresh store should have been provisioned first; an existing
      // store with no key is Recovery Mode, never a reset.
      throw KeyReleaseUnavailable(
        state,
        'No device key is available to release.',
      );
    }
    final Uint8List bytes;
    try {
      bytes = await keyFile.readAsBytes();
    } on io.FileSystemException catch (error) {
      throw KeyReleaseUnavailable(
        KeyVaultState.recoveryRequired,
        'Device key is unreadable: ${error.osError}',
      );
    }
    if (bytes.length != keyLengthBytes) {
      throw KeyReleaseUnavailable(
        KeyVaultState.recoveryRequired,
        'Device key has an unexpected length.',
      );
    }
    return _FileKeyLease(Uint8List.fromList(bytes));
  }

  Uint8List _generateKey() {
    final Uint8List key = Uint8List(keyLengthBytes);
    for (int i = 0; i < keyLengthBytes; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }

  void _restrictPermissions(io.File file) {
    if (io.Platform.isWindows) {
      return;
    }
    try {
      // Best-effort owner-only permissions for the key file.
      io.Process.runSync('chmod', <String>['600', file.path]);
    } on io.ProcessException {
      // The containing app-support directory is already user-private; treat a
      // missing chmod as non-fatal on constrained environments.
    }
  }
}

/// A defensive-copy lease that zeroizes its buffer on dispose.
final class _FileKeyLease implements KeyLease {
  _FileKeyLease(this._bytes);

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
