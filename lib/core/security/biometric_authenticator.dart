/// The app-lock biometric capability port (R-SEC-003).
///
/// The app lock is a presentation/session gate ([AppLockGate]); it decides
/// whether the current interactive session may reveal content. This port is the
/// narrow capability the gate uses to re-authenticate a locked session with the
/// device's biometric or device-credential prompt. It is deliberately plugin-
/// free so the app-lock flow is testable without `local_auth`; the concrete
/// adapter (`LocalAuthBiometricAuthenticator`) is composed at the root on
/// platforms that support it, and a [UnavailableBiometricAuthenticator] default
/// keeps every other platform (and the pre-wire app) working.
///
/// The port never releases key material and is never the encryption boundary —
/// that is the `KeyVault`. A successful authentication only lets the caller
/// mark the session unlocked ([AppLockGate.markUnlocked]).
library;

/// Whether a device biometric / credential prompt can be used right now.
enum BiometricAvailability {
  /// Hardware present and at least one factor (biometric or device credential)
  /// is enrolled, so a prompt can be shown.
  available,

  /// The device has no usable sensor / secure lock configured. Callers fall
  /// back gracefully (e.g. leave the session open or use a PIN surface) rather
  /// than trapping the user behind a prompt that can never succeed.
  unavailable,
}

/// The outcome of a single authentication attempt.
enum BiometricAuthOutcome {
  /// The user authenticated successfully.
  success,

  /// The user cancelled or the attempt failed without a permanent error.
  failed,

  /// The capability is unavailable (no hardware, not enrolled, or platform
  /// unsupported); callers degrade gracefully.
  unavailable,
}

/// The narrow biometric/device-credential capability behind the app lock.
abstract interface class BiometricAuthenticator {
  /// Reports whether a prompt can currently be shown. Never throws.
  Future<BiometricAvailability> availability();

  /// Prompts the user to authenticate with [reason] as the localized rationale.
  /// Returns [BiometricAuthOutcome.success] only on a confirmed unlock; any
  /// error, cancellation, or missing capability degrades to a non-success
  /// outcome without throwing.
  Future<BiometricAuthOutcome> authenticate({required String reason});
}

/// The safe default used on platforms without a biometric capability (desktop)
/// and before any adapter is wired. It reports the capability as unavailable so
/// the app-lock gate degrades gracefully instead of blocking the session.
final class UnavailableBiometricAuthenticator
    implements BiometricAuthenticator {
  const UnavailableBiometricAuthenticator();

  @override
  Future<BiometricAvailability> availability() async =>
      BiometricAvailability.unavailable;

  @override
  Future<BiometricAuthOutcome> authenticate({required String reason}) async =>
      BiometricAuthOutcome.unavailable;
}
