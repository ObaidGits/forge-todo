import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';

/// Unit tests for the single-window widget-mode controller. The window side
/// effects are asserted against a recording [NoopDesktopWindowManager] so the
/// orchestration is verified without a real desktop session.
void main() {
  ProviderContainer makeContainer(NoopDesktopWindowManager window) {
    return ProviderContainer(
      overrides: [
        desktopWindowManagerProvider.overrideWithValue(window),
        desktopSettingsStoreProvider.overrideWithValue(
          InMemoryDesktopSettingsStore(),
        ),
      ],
    );
  }

  test('given_full_mode_when_toggled_then_enters_widget_mode', () async {
    final NoopDesktopWindowManager window = NoopDesktopWindowManager();
    final ProviderContainer container = makeContainer(window);
    addTearDown(container.dispose);
    final DesktopWidgetController controller = container.read(
      desktopWidgetControllerProvider.notifier,
    );

    expect(
      container.read(desktopWidgetControllerProvider).mode,
      DesktopWidgetMode.full,
    );
    await controller.toggle();

    expect(
      container.read(desktopWidgetControllerProvider).mode,
      DesktopWidgetMode.widget,
    );
    expect(window.lastWidgetSpec, isNotNull);

    await controller.toggle();
    expect(
      container.read(desktopWidgetControllerProvider).mode,
      DesktopWidgetMode.full,
    );
    expect(window.enteredFullMode, isTrue);
  });

  test('given_wayland_when_entering_widget_then_discloses_unpinned', () async {
    // A platform that ignores always-on-top (models Wayland).
    final NoopDesktopWindowManager window = NoopDesktopWindowManager(
      alwaysOnTopSupported: false,
    );
    final ProviderContainer container = makeContainer(window);
    addTearDown(container.dispose);
    final DesktopWidgetController controller = container.read(
      desktopWidgetControllerProvider.notifier,
    );
    await controller.updatePreferences(
      const DesktopWidgetPreferences(enabled: true, alwaysOnTop: true),
    );

    await controller.enterWidgetMode();

    expect(
      container.read(desktopWidgetControllerProvider).alwaysOnTopHonored,
      isFalse,
    );
  });

  test('given_quick_add_when_requested_then_focuses_today_add', () async {
    final NoopDesktopWindowManager window = NoopDesktopWindowManager();
    final ProviderContainer container = makeContainer(window);
    addTearDown(container.dispose);
    final DesktopWidgetController controller = container.read(
      desktopWidgetControllerProvider.notifier,
    );
    final int before = container
        .read(desktopWidgetControllerProvider)
        .focusAddTick;

    await controller.requestQuickAdd();

    final DesktopWidgetState state = container.read(
      desktopWidgetControllerProvider,
    );
    expect(state.mode, DesktopWidgetMode.widget);
    expect(state.activeTab, WidgetTab.today);
    expect(state.focusAddTick, greaterThan(before));
  });

  test('given_locked_position_when_drag_then_no_op', () async {
    final NoopDesktopWindowManager window = NoopDesktopWindowManager();
    final ProviderContainer container = makeContainer(window);
    addTearDown(container.dispose);
    final DesktopWidgetController controller = container.read(
      desktopWidgetControllerProvider.notifier,
    );
    await controller.updatePreferences(
      const DesktopWidgetPreferences(enabled: true, lockPosition: true),
    );

    // Should not throw; lock simply suppresses the drag request.
    await controller.startDragging();
  });
}
