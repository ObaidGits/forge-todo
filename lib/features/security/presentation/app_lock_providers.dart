/// Composition seams for the app-lock biometric capability (R-SEC-003).
///
/// The app lock itself is the plugin-free [AppLockGate] (exposed via
/// `appLockGateProvider`). This seam adds the biometric/device-credential
/// capability the gate uses to re-authenticate a locked session. The default is
/// the safe [UnavailableBiometricAuthenticator] so desktop and the pre-wire app
/// degrade gracefully; the composition root overrides it with the concrete
/// `local_auth` adapter on platforms that support it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/core/security/biometric_authenticator.dart';
import 'package:forge/features/home/presentation/inbound_capture_providers.dart';

/// The biometric/device-credential capability behind the app lock. Defaults to
/// the unavailable authenticator; overridden at the root on mobile.
final Provider<BiometricAuthenticator> biometricAuthenticatorProvider =
    Provider<BiometricAuthenticator>(
      (Ref ref) => const UnavailableBiometricAuthenticator(),
    );

/// Attempts to unlock the current session with a device biometric / credential
/// prompt, degrading gracefully when the capability is unavailable.
///
/// Returns the resulting [AppLockStatus]. When the lock is not configured or
/// biometrics are unavailable the session is left in its current (open) state
/// so the local-first app is never trapped behind a prompt that can't succeed.
final class AppLockController {
  const AppLockController({required this.gate, required this.authenticator});

  final AppLockGate gate;
  final BiometricAuthenticator authenticator;

  Future<AppLockStatus> unlock({String reason = 'Unlock Forge'}) async {
    if (!gate.isConfigured || gate.isContentVisible) {
      return gate.status;
    }
    final BiometricAvailability availability = await authenticator
        .availability();
    if (availability == BiometricAvailability.unavailable) {
      // No usable factor: leave the gate as-is for a non-biometric fallback
      // (PIN surface / explicit unlock) rather than blocking indefinitely.
      return gate.status;
    }
    final BiometricAuthOutcome outcome = await authenticator.authenticate(
      reason: reason,
    );
    if (outcome == BiometricAuthOutcome.success) {
      gate.markUnlocked();
    }
    return gate.status;
  }
}

/// The app-lock controller composed from the live gate and the wired
/// authenticator capability.
final Provider<AppLockController> appLockControllerProvider =
    Provider<AppLockController>(
      (Ref ref) => AppLockController(
        gate: ref.watch(appLockGateProvider),
        authenticator: ref.watch(biometricAuthenticatorProvider),
      ),
    );
