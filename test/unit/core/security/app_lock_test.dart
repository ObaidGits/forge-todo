import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/core/security/key_vault_ports.dart';

void main() {
  group('AppLockGate session semantics', () {
    test('an unconfigured gate is always open', () {
      final AppLockGate gate = AppLockGate(elapsed: () => Duration.zero);

      expect(gate.status, AppLockStatus.notConfigured);
      expect(gate.isConfigured, isFalse);
      expect(gate.isContentVisible, isTrue);
      // Session verbs are inert while unconfigured.
      gate.lock();
      expect(gate.status, AppLockStatus.notConfigured);
    });

    test('configuring starts locked and unlocks on authentication', () {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
      );

      expect(gate.status, AppLockStatus.locked);
      expect(gate.isContentVisible, isFalse);
      gate.markUnlocked();
      expect(gate.status, AppLockStatus.unlocked);
      expect(gate.isContentVisible, isTrue);
    });

    test('idle beyond the auto-lock window locks on foreground', () {
      Duration now = Duration.zero;
      final AppLockGate gate = AppLockGate(
        elapsed: () => now,
        configured: true,
        autoLockAfter: const Duration(minutes: 1),
      )..markUnlocked();

      gate.onBackgrounded();
      now += const Duration(seconds: 90);
      gate.onForegrounded();

      expect(gate.status, AppLockStatus.locked);
    });

    test('returning within the window keeps the session unlocked', () {
      Duration now = Duration.zero;
      final AppLockGate gate = AppLockGate(
        elapsed: () => now,
        configured: true,
        autoLockAfter: const Duration(minutes: 1),
      )..markUnlocked();

      gate.onBackgrounded();
      now += const Duration(seconds: 30);
      gate.onForegrounded();

      expect(gate.status, AppLockStatus.unlocked);
    });

    test('disable returns to an always-open session', () {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
      )..disable();

      expect(gate.status, AppLockStatus.notConfigured);
      expect(gate.isContentVisible, isTrue);
    });
  });

  group('privacy controls', () {
    test('locked session hides previews per privacy settings', () {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
      );

      expect(gate.notificationPreviewVisible(), isFalse);
      expect(gate.widgetPreviewVisible(), isFalse);
      expect(gate.appSwitcherContentVisible(), isFalse);
    });

    test('unlocked session reveals previews unless switcher is obscured', () {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
      )..markUnlocked();

      expect(gate.notificationPreviewVisible(), isTrue);
      expect(gate.widgetPreviewVisible(), isTrue);
      // App-switcher snapshot stays obscured by default even when unlocked.
      expect(gate.appSwitcherContentVisible(), isFalse);
    });

    test('opting out of preview hiding shows previews while locked', () {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
        privacy: const PrivacyControls(
          hideNotificationPreviews: false,
          hideWidgetPreviews: false,
          obscureAppSwitcherSnapshot: false,
        ),
      );

      expect(gate.notificationPreviewVisible(), isTrue);
      expect(gate.widgetPreviewVisible(), isTrue);
    });
  });

  group('background access policy', () {
    test('only no-presence device storage may release headless', () {
      expect(
        backgroundAccessAllowed(VaultProtection.deviceSecureStore),
        isTrue,
      );
      expect(backgroundAccessAllowed(VaultProtection.biometric), isFalse);
      expect(backgroundAccessAllowed(VaultProtection.pinFallback), isFalse);
    });
  });
}
