import 'dart:typed_data';

import 'package:forge/core/security/key_vault.dart';

/// Deterministic in-memory [KeyVault] for tests.
///
/// It enforces the production invariant that existing ciphertext can never mint
/// a replacement key, and it releases zeroized-on-dispose leases.
final class FakeKeyLease implements KeyLease {
  FakeKeyLease(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

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

final class FakeKeyVault implements KeyVault {
  FakeKeyVault.absent({this.encryptedStoreExists = false})
    : _state = KeyVaultState.absent;

  FakeKeyVault.available(List<int> key, {this.encryptedStoreExists = true})
    : _key = Uint8List.fromList(key),
      _state = KeyVaultState.available {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Must not be empty.');
    }
  }

  @override
  final bool encryptedStoreExists;

  Uint8List? _key;
  KeyVaultState _state;
  int releaseCount = 0;

  @override
  KeyVaultState get state => _state;

  @override
  Future<FakeKeyLease> release() async {
    releaseCount += 1;
    final Uint8List? key = _key;
    if (_state != KeyVaultState.available || key == null) {
      throw KeyReleaseUnavailable(_state, 'Key release is unavailable.');
    }
    return FakeKeyLease(key);
  }

  void create(List<int> key) {
    if (_state != KeyVaultState.absent) {
      throw KeyReleaseUnavailable(_state, 'A key already exists.');
    }
    if (encryptedStoreExists) {
      _state = KeyVaultState.recoveryRequired;
      throw const KeyReleaseUnavailable(
        KeyVaultState.recoveryRequired,
        'Existing ciphertext forbids replacement-key creation.',
      );
    }
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Must not be empty.');
    }
    _key = Uint8List.fromList(key);
    _state = KeyVaultState.available;
  }

  void lock() {
    _requireKey();
    _state = KeyVaultState.locked;
  }

  void unlock() {
    _requireKey();
    _state = KeyVaultState.available;
  }

  void revokePermission() {
    _requireKey();
    _state = KeyVaultState.permissionRevoked;
  }

  void requireRecovery() {
    _state = KeyVaultState.recoveryRequired;
  }

  void delete() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
    _state = KeyVaultState.deleted;
  }

  void _requireKey() {
    if (_key == null || _state == KeyVaultState.deleted) {
      throw KeyReleaseUnavailable(_state, 'No key exists.');
    }
  }
}
