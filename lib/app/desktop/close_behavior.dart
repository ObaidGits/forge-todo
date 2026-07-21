import 'package:forge/app/desktop/desktop_settings_store.dart';

/// What Forge does when the user closes the main desktop window (ux-design §9:
/// "Tray behavior is opt-in and 'close versus minimize' is explicit. No
/// background process surprises.").
///
/// The default is [exitApp] so nothing keeps running in the background unless
/// the user opts in. There are no companion/floating windows in V1; those
/// remain Post-V1 (ux-design §9, §13).
enum CloseBehavior {
  /// Quit the application when the window is closed (default, no surprises).
  exitApp('exit'),

  /// Hide the window to the system tray and keep the app resident. Opt-in.
  minimizeToTray('tray');

  const CloseBehavior(this.wire);

  /// The stable persisted token.
  final String wire;

  static CloseBehavior fromWire(String? wire) {
    for (final CloseBehavior value in CloseBehavior.values) {
      if (value.wire == wire) {
        return value;
      }
    }
    return CloseBehavior.exitApp;
  }
}

/// The action the shell should take for a window-close request, derived from
/// the user's [CloseBehavior] preference.
enum CloseAction {
  /// Quit the process.
  quit,

  /// Hide to tray and stay resident.
  hideToTray,
}

/// The system-tray control surface. Integration boundary over a concrete tray
/// plugin (e.g. tray_manager); the real binding needs a live desktop session
/// and is a MANUAL-* follow-up. The abstraction lets close/tray decisions be
/// unit-tested with a fake.
abstract interface class TrayController {
  /// Ensures a tray icon exists (used when close-to-tray is enabled).
  Future<void> ensureVisible();

  /// Removes the tray icon (used when the user switches back to quit-on-close).
  Future<void> remove();

  /// Hides the main window to the tray.
  Future<void> hideWindow();

  /// Shows and focuses the main window from the tray.
  Future<void> showWindow();

  /// Quits the application.
  Future<void> quit();
}

/// Reads and writes the close-to-tray preference and resolves close requests.
///
/// The preference lives in the local [DesktopSettingsStore] (device-local,
/// not synced). Enabling tray mode ensures a tray icon exists; disabling it
/// removes the icon so the app never lingers invisibly.
final class CloseBehaviorService {
  CloseBehaviorService({
    required this.store,
    required this.tray,
    this.storageKey = 'desktop.close_behavior',
  });

  final DesktopSettingsStore store;
  final TrayController tray;
  final String storageKey;

  /// The current preference; defaults to [CloseBehavior.exitApp].
  Future<CloseBehavior> current() async =>
      CloseBehavior.fromWire(await store.read(storageKey));

  /// Persists [behavior] and reconciles the tray icon to match it.
  Future<void> set(CloseBehavior behavior) async {
    await store.write(storageKey, behavior.wire);
    if (behavior == CloseBehavior.minimizeToTray) {
      await tray.ensureVisible();
    } else {
      await tray.remove();
    }
  }

  /// Maps the current preference to a [CloseAction] for a window-close request.
  Future<CloseAction> resolveClose() async {
    final CloseBehavior behavior = await current();
    return behavior == CloseBehavior.minimizeToTray
        ? CloseAction.hideToTray
        : CloseAction.quit;
  }

  /// Handles a window-close request end to end: either hides to tray or quits.
  Future<CloseAction> handleClose() async {
    final CloseAction action = await resolveClose();
    switch (action) {
      case CloseAction.hideToTray:
        await tray.hideWindow();
      case CloseAction.quit:
        await tray.quit();
    }
    return action;
  }
}
