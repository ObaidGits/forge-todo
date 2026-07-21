import 'dart:typed_data';

import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/key_vault_machine.dart';

/// Bridges the production [KeyVaultMachine] to the DB-neutral [KeyVault] port
/// consumed by the database runtime bootstrap.
///
/// The runtime asks the vault to *release* (never *replace*) the key. This
/// adapter only ever exposes the live key when the machine is in
/// [VaultAvailable]; every other state throws [KeyReleaseUnavailable] so the
/// runtime routes existing ciphertext into Recovery Mode instead of minting a
/// replacement key.
final class MachineBackedKeyVault implements KeyVault {
  MachineBackedKeyVault(this._machine);

  final KeyVaultMachine _machine;

  @override
  KeyVaultState get state => _machine.state.kind;

  @override
  bool get encryptedStoreExists {
    // A persisted database identity means ciphertext depends on this vault.
    if (_machine.storage.database != null) {
      return true;
    }
    // Defensive: any non-fresh lifecycle state also implies dependence.
    return switch (_machine.state) {
      VaultAbsent() || VaultCreating() || VaultDeleted() => false,
      _ => true,
    };
  }

  @override
  Future<KeyLease> release() async {
    final VaultState current = _machine.state;
    if (current is! VaultAvailable) {
      throw KeyReleaseUnavailable(
        current.kind,
        'Key release is unavailable in state ${current.kind.name}.',
      );
    }
    return _MachineKeyLease(current.key.copyBytes());
  }
}

/// A defensive-copy lease that zeroizes its buffer on dispose.
final class _MachineKeyLease implements KeyLease {
  _MachineKeyLease(this._bytes);

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
