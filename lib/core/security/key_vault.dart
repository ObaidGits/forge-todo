import 'dart:typed_data';

import 'package:forge/core/database/runtime.dart';

/// Fail-closed lifecycle states for the device key custodian.
///
/// The vault never transitions from a state that implies existing ciphertext
/// (`available`, `locked`, `recoveryRequired`, ...) back into `absent` as a way
/// to mint a replacement key. Existing encrypted data can only ever be opened
/// or enter Recovery Mode; it can never silently reset a key. This invariant is
/// the security spine of `R-SEC-001`/`R-SEC-002`.
enum KeyVaultState {
  /// No key material exists and no encrypted store depends on one yet.
  absent,

  /// A key is being provisioned for a brand-new (empty) store.
  creating,

  /// A key exists and can be released without additional user presence.
  available,

  /// A key exists but the app-lock/session gate withholds release.
  locked,

  /// The OS key policy currently refuses release (e.g. biometric revoked).
  permissionRevoked,

  /// Too many failed release attempts; release is temporarily blocked.
  retryLimited,

  /// A crash-safe key rotation is in progress.
  rotating,

  /// Ciphertext exists but its key is unavailable/unrecoverable. The only safe
  /// outcome is non-destructive Recovery Mode.
  recoveryRequired,

  /// A user-requested deletion is in progress.
  deleting,

  /// Key material has been destroyed.
  deleted,
}

/// A short-lived, owner-disposed view over released key bytes.
///
/// Callers copy the bytes for the minimum window required to configure the
/// cipher, then dispose the lease so the buffer is zeroized.
abstract interface class KeyLease implements AsyncResource {
  /// Returns a defensive copy of the key bytes. Throws once disposed.
  Uint8List copyBytes();

  bool get isDisposed;
}

/// Custodian of the profile database key.
///
/// The runtime asks the vault to *release* (never *replace*) the key during
/// bootstrap. Provisioning of a first key for an empty store is a separate
/// vault concern; opening existing ciphertext only ever releases.
abstract interface class KeyVault {
  KeyVaultState get state;

  /// Whether an encrypted store already depends on this vault's key. When true,
  /// a failed release must lead to Recovery Mode, never key replacement.
  bool get encryptedStoreExists;

  /// Releases the current key as a disposable lease.
  ///
  /// Throws [KeyReleaseUnavailable] when the current [state] cannot release.
  Future<KeyLease> release();
}

/// Raised when [KeyVault.release] is called in a non-releasing state.
final class KeyReleaseUnavailable implements Exception {
  const KeyReleaseUnavailable(this.state, [this.message]);

  final KeyVaultState state;
  final String? message;

  @override
  String toString() =>
      'KeyReleaseUnavailable($state${message == null ? '' : ', $message'})';
}
