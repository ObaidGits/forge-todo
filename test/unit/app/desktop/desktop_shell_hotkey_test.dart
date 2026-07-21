import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_bindings.dart';

/// Unit tests for the [DesktopShell] global-hotkey wiring (task §6).
///
/// These exercise the [GlobalHotkeyBinder] abstraction directly (no plugins,
/// no real window/tray) so they run headless on the Dart VM: the shell must
/// register the toggle hotkey, route it to `onToggleWidget`, honor the
/// enable/disable Settings preference, and degrade without crashing when the
/// platform refuses the global grab.
void main() {
  group('DesktopShell global hotkey', () {
    late _FakeHotkeyBinder binder;
    late DesktopShell shell;
    late int toggleCount;

    DesktopShellActions actions() => DesktopShellActions(
      onOpenFull: () async {},
      onToggleWidget: () async => toggleCount++,
      onQuickAdd: () async {},
      onClose: () async {},
      onQuit: () async {},
    );

    setUp(() {
      toggleCount = 0;
      binder = _FakeHotkeyBinder();
      shell = DesktopShell(hotkeys: binder);
      shell.bind(actions());
    });

    test(
      'given_enabled_when_applied_then_registers_and_routes_toggle',
      () async {
        await shell.applyHotkeyEnabled(true);

        expect(binder.registerCalls, 1);
        expect(binder.onToggle, isNotNull);

        await binder.onToggle!();
        expect(toggleCount, 1);
      },
    );

    test('given_disabled_when_applied_then_unregisters', () async {
      await shell.applyHotkeyEnabled(true);
      await shell.applyHotkeyEnabled(false);

      expect(binder.unregisterCalls, 1);
    });

    test(
      'given_already_registered_when_enabled_again_then_no_duplicate',
      () async {
        await shell.applyHotkeyEnabled(true);
        await shell.applyHotkeyEnabled(true);

        expect(binder.registerCalls, 1);
      },
    );

    test(
      'given_registration_fails_when_enabled_then_degrades_and_retries',
      () async {
        binder.succeed = false;
        await shell.applyHotkeyEnabled(true);
        expect(binder.registerCalls, 1);

        // Not registered, so a later enable retries rather than short-circuiting.
        binder.succeed = true;
        await shell.applyHotkeyEnabled(true);
        expect(binder.registerCalls, 2);

        await binder.onToggle!();
        expect(toggleCount, 1);
      },
    );

    test('given_binder_throws_when_enabled_then_never_crashes', () async {
      binder.throwOnRegister = true;
      await expectLater(shell.applyHotkeyEnabled(true), completes);
    });
  });
}

/// A plugin-free [GlobalHotkeyBinder] test double that records calls and lets
/// the test drive the registered toggle callback.
final class _FakeHotkeyBinder implements GlobalHotkeyBinder {
  bool succeed = true;
  bool throwOnRegister = false;
  int registerCalls = 0;
  int unregisterCalls = 0;
  Future<void> Function()? onToggle;

  @override
  Future<bool> register(Future<void> Function() onToggle) async {
    registerCalls++;
    if (throwOnRegister) {
      throw StateError('register failed');
    }
    if (succeed) {
      this.onToggle = onToggle;
    }
    return succeed;
  }

  @override
  Future<void> unregister() async {
    unregisterCalls++;
    onToggle = null;
  }
}
