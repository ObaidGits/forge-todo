import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/autostart_controller.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/app/desktop/window_state.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';

/// The device-local desktop settings store.
///
/// The default is in-memory so the shell composes safely in tests and on
/// platforms without a writable profile directory. The production composition
/// root overrides this with a [FileDesktopSettingsStore] under the app-support
/// directory. These values are never synced (R-SYNC-002 local-only class).
final Provider<DesktopSettingsStore> desktopSettingsStoreProvider =
    Provider<DesktopSettingsStore>((Ref ref) => InMemoryDesktopSettingsStore());

/// The system-tray control surface. Defaults to a no-op so the app runs without
/// a real desktop session (tests, headless, mobile). The concrete tray binding
/// (tray_manager) requires a live desktop and is a MANUAL-* follow-up
/// (MANUAL-DESKTOP-TRAY).
final Provider<TrayController> trayControllerProvider =
    Provider<TrayController>((Ref ref) => const NoopTrayController());

/// The window control surface. Defaults to a no-op recorder so window
/// persistence orchestration is testable without a real window. The concrete
/// binding (window_manager) is a MANUAL-* follow-up (MANUAL-DESKTOP-WINDOW).
final Provider<WindowController> windowControllerProvider =
    Provider<WindowController>((Ref ref) => InMemoryWindowController());

/// Reads and persists the close-to-tray preference and resolves close requests.
final Provider<CloseBehaviorService> closeBehaviorServiceProvider =
    Provider<CloseBehaviorService>((Ref ref) {
      return CloseBehaviorService(
        store: ref.watch(desktopSettingsStoreProvider),
        tray: ref.watch(trayControllerProvider),
      );
    });

/// Persists and restores window geometry across launches.
final Provider<WindowStateService> windowStateServiceProvider =
    Provider<WindowStateService>((Ref ref) {
      return WindowStateService(
        store: ref.watch(desktopSettingsStoreProvider),
        controller: ref.watch(windowControllerProvider),
      );
    });

/// The live desktop window manager used by the sticky-widget controller.
/// Defaults to a no-op recorder so the shell composes without a real window
/// (tests, headless, mobile). The production composition root overrides this
/// with the `window_manager` binding on desktop only.
final Provider<DesktopWindowManager> desktopWindowManagerProvider =
    Provider<DesktopWindowManager>((Ref ref) => NoopDesktopWindowManager());

/// The OS "launch at login" controller. Defaults to a no-op so the settings
/// toggle composes without a real desktop session; the production composition
/// root overrides this with the `launch_at_startup` binding on desktop only.
final Provider<AutostartController> autostartControllerProvider =
    Provider<AutostartController>((Ref ref) => NoopAutostartController());

/// The device-local desktop-widget preferences store.
final Provider<DesktopWidgetPreferencesStore>
desktopWidgetPreferencesStoreProvider = Provider<DesktopWidgetPreferencesStore>(
  (Ref ref) => DesktopWidgetPreferencesStore(
    store: ref.watch(desktopSettingsStoreProvider),
  ),
);

/// The preferences the desktop-widget controller starts from. Defaults to the
/// safe defaults; the composition root overrides this with the values loaded
/// from disk during bootstrap so the controller starts in the user's last
/// state without an async gap.
final Provider<DesktopWidgetPreferences>
desktopWidgetInitialPreferencesProvider = Provider<DesktopWidgetPreferences>(
  (Ref ref) => DesktopWidgetPreferences.defaults,
);

/// The single-window widget-mode controller (task §2). It resolves its
/// dependencies (window manager, preferences store, window-state service,
/// initial preferences) from the providers above via its Notifier `ref`.
final NotifierProvider<DesktopWidgetController, DesktopWidgetState>
desktopWidgetControllerProvider =
    NotifierProvider<DesktopWidgetController, DesktopWidgetState>(
      DesktopWidgetController.new,
    );

/// The current close behavior, editable from Settings. Reads from the store on
/// first watch and updates the store (and tray) when [set] is called.
final class CloseBehaviorController extends AsyncNotifier<CloseBehavior> {
  @override
  Future<CloseBehavior> build() =>
      ref.watch(closeBehaviorServiceProvider).current();

  Future<void> set(CloseBehavior behavior) async {
    state = AsyncData<CloseBehavior>(behavior);
    await ref.read(closeBehaviorServiceProvider).set(behavior);
  }
}

final AsyncNotifierProvider<CloseBehaviorController, CloseBehavior>
closeBehaviorProvider =
    AsyncNotifierProvider<CloseBehaviorController, CloseBehavior>(
      CloseBehaviorController.new,
    );

/// A no-op [TrayController] used when no real desktop session is available.
final class NoopTrayController implements TrayController {
  const NoopTrayController();

  @override
  Future<void> ensureVisible() async {}

  @override
  Future<void> remove() async {}

  @override
  Future<void> hideWindow() async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> quit() async {}
}

/// A [WindowController] that records the last applied state instead of touching
/// a real OS window. Used as the default binding and in tests.
final class InMemoryWindowController implements WindowController {
  InMemoryWindowController([WindowState? initial])
    : _state = initial ?? WindowState.initial;

  WindowState _state;

  WindowState get lastApplied => _state;

  @override
  Future<void> apply(WindowState state) async => _state = state;

  @override
  Future<WindowState> current() async => _state;
}
