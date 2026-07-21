/// The production [BiometricAuthenticator] over the `local_auth` plugin
/// (R-SEC-003).
///
/// This is the only place `package:local_auth` is imported. It adapts the
/// plugin to the plugin-free [BiometricAuthenticator] port so the app-lock gate
/// stays testable and the rest of the app never depends on the plugin. Every
/// plugin call is defensive: a missing sensor, no enrolled factor, a user
/// cancellation, or any `PlatformException` degrades to a non-success outcome
/// instead of throwing, so a device without biometrics never traps the user or
/// crashes the local-first app.
library;

import 'package:forge/core/security/biometric_authenticator.dart';
import 'package:local_auth/local_auth.dart';

final class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuth})
    : _auth = localAuth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricAvailability> availability() async {
    try {
      // `isDeviceSupported` covers hardware plus a configured secure lock —
      // enough for `authenticate` below, which allows the device-credential
      // fallback when no biometric is enrolled.
      final bool supported = await _auth.isDeviceSupported();
      return supported
          ? BiometricAvailability.available
          : BiometricAvailability.unavailable;
    } on Object {
      return BiometricAvailability.unavailable;
    }
  }

  @override
  Future<BiometricAuthOutcome> authenticate({required String reason}) async {
    try {
      final bool ok = await _auth.authenticate(
        localizedReason: reason,
        // Allow the non-biometric device credential (PIN/pattern/password) so a
        // device with a secure lock but no enrolled biometric can still unlock.
        biometricOnly: false,
        // Retry across a backgrounding rather than failing the prompt.
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricAuthOutcome.success : BiometricAuthOutcome.failed;
    } on LocalAuthException {
      // NotAvailable / NotEnrolled / PasscodeNotSet and similar map to an
      // unavailable capability so the caller degrades gracefully.
      return BiometricAuthOutcome.unavailable;
    } on Object {
      return BiometricAuthOutcome.failed;
    }
  }
}
