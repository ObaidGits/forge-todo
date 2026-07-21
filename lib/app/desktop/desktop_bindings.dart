import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:forge/app/desktop/autostart_controller.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/app/desktop/window_state.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// NOTE (global hotkey, task §6): the summon/toggle hotkey is implemented via
// `hotkey_manager`, whose Linux plugin needs the system `keybinder-3.0`
// development package at build time (now installed here). The hotkey stays
// abstracted behind [GlobalHotkeyBinder]: the default [NoopGlobalHotkeyBinder]
// keeps tests/headless/mobile safe, and the desktop composition root wires the
// real [HotkeyManagerGlobalHotkeyBinder] (Ctrl+Alt+T -> onToggle). Registration
// is best-effort: under Wayland or without a keybinder runtime it is caught and
// degrades to the no-op behavior. Tray + Settings still toggle the widget, so
// the feature is fully usable even when the global hotkey cannot register.

/// Concrete desktop-shell bindings over `window_manager`, `tray_manager`,
/// `hotkey_manager`, and `launch_at_startup`.
///
/// Everything here is desktop-only and MUST NOT be constructed on Android/iOS
/// (the plugin Dart APIs compile everywhere but the native channels do not
/// exist on mobile). Callers guard construction by platform. Each operation is
/// best-effort: a missing capability degrades gracefully and never crashes the
/// single-engine app that owns the encrypted DatabaseRuntime writer lock.

/// Detects the desktop windowing environment so the shell can disclose limited
/// capabilities (e.g. always-on-top under Wayland) rather than pretend.
abstract final class DesktopEnvironment {
  /// True when running under a Wayland session, where a client cannot reliably
  /// force always-on-top or absolute positioning (task platform notes).
  static bool get isWayland {
    if (kIsWeb || !io.Platform.isLinux) {
      return false;
    }
    final Map<String, String> env = io.Platform.environment;
    if ((env['WAYLAND_DISPLAY'] ?? '').isNotEmpty) {
      return true;
    }
    return (env['XDG_SESSION_TYPE'] ?? '').toLowerCase() == 'wayland';
  }
}

/// The tray asset paths (registered in pubspec `assets/tray/`).
abstract final class DesktopTrayAssets {
  static String get iconPath => io.Platform.isWindows
      ? 'assets/tray/forge_tray.ico'
      : 'assets/tray/forge_tray.png';
}

/// Initializes `window_manager` before the first frame: applies the initial
/// titled geometry, prevents the raw OS close so the shell can decide
/// hide-to-tray vs quit, and clears any stale global hotkeys. Safe to call once
/// from `main` on desktop only.
Future<void> initializeDesktopWindowManager() async {
  await windowManager.ensureInitialized();
  final WindowOptions options = WindowOptions(
    size: Size(WindowState.initial.width, WindowState.initial.height),
    minimumSize: const Size(WindowState.minWidth, WindowState.minHeight),
    center: true,
    title: 'Forge',
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  // Intercept the window-close button so it can hide to tray when the user
  // opted in (WindowListener.onWindowClose fires instead of a hard quit).
  await windowManager.setPreventClose(true);
}

/// Binds a global (system-wide) summon/toggle hotkey. The default is a no-op
/// because the Linux `hotkey_manager` plugin needs `keybinder-3.0`, which is
/// unavailable in this build (see the note at the top of this file). Swap in a
/// real binder on platforms where the hotkey plugin is available.
abstract interface class GlobalHotkeyBinder {
  /// Registers the toggle hotkey (Ctrl+Alt+T). Best-effort; returns false when
  /// the platform/build cannot register a global shortcut.
  Future<bool> register(Future<void> Function() onToggle);

  /// Removes any registered hotkey.
  Future<void> unregister();
}

/// The default global-hotkey binder: does nothing and reports unavailable.
final class NoopGlobalHotkeyBinder implements GlobalHotkeyBinder {
  const NoopGlobalHotkeyBinder();

  @override
  Future<bool> register(Future<void> Function() onToggle) async {
    debugPrint(
      '[forge.desktop] global hotkey unavailable in this build '
      '(no-op binder); use the tray or Settings to toggle.',
    );
    return false;
  }

  @override
  Future<void> unregister() async {}
}

/// A `hotkey_manager`-backed [GlobalHotkeyBinder] that registers a system-wide
/// Ctrl+Alt+T shortcut mapped to the widget-mode toggle (task §6).
///
/// Desktop-only: [register] is a guarded no-op on web/mobile so the native
/// channels are never touched off desktop. Every step is best-effort — under
/// Wayland (which cannot always grab global shortcuts) or without a
/// `keybinder-3.0` runtime the platform rejects registration; that is caught
/// and degraded to the documented no-op with a logged notice, never a crash.
final class HotkeyManagerGlobalHotkeyBinder implements GlobalHotkeyBinder {
  HotkeyManagerGlobalHotkeyBinder();

  /// The default summon/toggle hotkey: Ctrl+Alt+T (task §6). Not `const`
  /// because [HotKey] mints a per-instance identifier.
  static final HotKey _toggleHotKey = HotKey(
    key: PhysicalKeyboardKey.keyT,
    modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );

  bool _registered = false;

  /// True on the desktop platforms Forge ships. Mobile/web must never reach the
  /// hotkey plugin's native channels.
  static bool get _isDesktop {
    if (kIsWeb) {
      return false;
    }
    return io.Platform.isLinux || io.Platform.isWindows || io.Platform.isMacOS;
  }

  @override
  Future<bool> register(Future<void> Function() onToggle) async {
    if (!_isDesktop) {
      return false;
    }
    try {
      // Clear any stale system registration (e.g. a previous run that did not
      // shut down cleanly) before (re)registering our toggle.
      await hotKeyManager.unregisterAll();
      await hotKeyManager.register(
        _toggleHotKey,
        keyDownHandler: (HotKey _) => unawaited(onToggle()),
      );
      _registered = true;
      return true;
    } on Object catch (error) {
      // Wayland or a missing keybinder runtime rejects the grab; degrade to the
      // documented no-op behavior instead of crashing the single-engine app.
      debugPrint(
        '[forge.desktop] global hotkey registration failed ($error); '
        'use the tray or Settings to toggle the widget.',
      );
      _registered = false;
      return false;
    }
  }

  @override
  Future<void> unregister() async {
    if (!_isDesktop || !_registered) {
      return;
    }
    try {
      await hotKeyManager.unregister(_toggleHotKey);
    } on Object {
      // Best-effort: a failed unregister must never crash teardown.
    }
    _registered = false;
  }
}

/// `window_manager`-backed [DesktopWindowManager]: toggles the single window
/// between the full titled app and a small frameless always-on-top sticky.
final class WindowManagerDesktopWindowManager implements DesktopWindowManager {
  const WindowManagerDesktopWindowManager();

  @override
  Future<bool> enterWidgetMode(WidgetWindowSpec spec) async {
    try {
      await windowManager.setMinimumSize(const Size(260, 300));
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setAsFrameless();
      await windowManager.setSize(Size(spec.width, spec.height));
      await windowManager.setResizable(true);
      await setAlwaysOnTop(spec.alwaysOnTop);
      await setOpacity(spec.opacity);
      await windowManager.setSkipTaskbar(spec.skipTaskbar);
      await windowManager.show();
    } on Object {
      // Best-effort: leave the window as-is if the platform rejected a step.
    }
    // Under Wayland the always-on-top request cannot be honored/verified.
    return !(spec.alwaysOnTop && DesktopEnvironment.isWayland);
  }

  @override
  Future<void> enterFullMode(WindowState restore) async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setOpacity(1.0);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(
        const Size(WindowState.minWidth, WindowState.minHeight),
      );
      await windowManager.setResizable(true);
      if (restore.x != null && restore.y != null) {
        await windowManager.setBounds(
          Rect.fromLTWH(restore.x!, restore.y!, restore.width, restore.height),
        );
      } else {
        await windowManager.setSize(Size(restore.width, restore.height));
        await windowManager.center();
      }
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // Best-effort restore.
    }
  }

  @override
  Future<bool> setAlwaysOnTop(bool value) async {
    try {
      await windowManager.setAlwaysOnTop(value);
    } on Object {
      // ignore
    }
    return !(value && DesktopEnvironment.isWayland);
  }

  @override
  Future<void> setOpacity(double opacity) async {
    try {
      await windowManager.setOpacity(opacity);
    } on Object {
      // Opacity is unsupported on some Linux compositors; ignore.
    }
  }

  @override
  Future<void> startDragging() async {
    try {
      await windowManager.startDragging();
    } on Object {
      // ignore
    }
  }

  @override
  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hide() async => windowManager.hide();

  @override
  Future<bool> isVisible() async {
    try {
      return await windowManager.isVisible();
    } on Object {
      return true;
    }
  }

  @override
  Future<WindowState> currentState() async {
    try {
      final Rect bounds = await windowManager.getBounds();
      return WindowState(
        width: bounds.width,
        height: bounds.height,
        x: bounds.left,
        y: bounds.top,
      );
    } on Object {
      return WindowState.initial;
    }
  }
}

/// `window_manager`-backed [WindowController] for full-window geometry
/// persistence (used by [WindowStateService]).
final class WindowManagerWindowController implements WindowController {
  const WindowManagerWindowController();

  @override
  Future<void> apply(WindowState state) async {
    try {
      if (state.x != null && state.y != null) {
        await windowManager.setBounds(
          Rect.fromLTWH(state.x!, state.y!, state.width, state.height),
        );
      } else {
        await windowManager.setSize(Size(state.width, state.height));
        await windowManager.center();
      }
    } on Object {
      // Best-effort geometry restore.
    }
  }

  @override
  Future<WindowState> current() async {
    try {
      final Rect bounds = await windowManager.getBounds();
      return WindowState(
        width: bounds.width,
        height: bounds.height,
        x: bounds.left,
        y: bounds.top,
      );
    } on Object {
      return WindowState.initial;
    }
  }
}

/// `tray_manager`-backed [TrayController]: manages the system-tray icon and its
/// context menu, and hides/shows/quits the single window. Menu-item routing is
/// handled by the [DesktopShell] listener; this adapter owns icon lifecycle and
/// window visibility so [CloseBehaviorService] can drive it too.
final class TrayManagerTrayController implements TrayController {
  const TrayManagerTrayController();

  @override
  Future<void> ensureVisible() async {
    try {
      await trayManager.setIcon(DesktopTrayAssets.iconPath);
      await trayManager.setToolTip('Forge');
      await trayManager.setContextMenu(buildForgeTrayMenu());
    } on Object {
      // A missing StatusNotifier host (e.g. headless/xvfb) is non-fatal.
    }
  }

  @override
  Future<void> remove() async {
    try {
      await trayManager.destroy();
    } on Object {
      // ignore
    }
  }

  @override
  Future<void> hideWindow() async {
    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } on Object {
      // ignore
    }
  }

  @override
  Future<void> showWindow() async {
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // ignore
    }
  }

  @override
  Future<void> quit() async {
    try {
      await trayManager.destroy();
    } on Object {
      // ignore
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}

/// Stable tray menu-item keys routed by [DesktopShell].
abstract final class TrayMenuKeys {
  static const String openFull = 'open_full';
  static const String toggleWidget = 'toggle_widget';
  static const String quickAdd = 'quick_add';
  static const String quit = 'quit';
}

/// Builds the Forge tray context menu (task §4).
Menu buildForgeTrayMenu() => Menu(
  items: <MenuItem>[
    MenuItem(key: TrayMenuKeys.openFull, label: 'Open Forge'),
    MenuItem(key: TrayMenuKeys.toggleWidget, label: 'Show/Hide widget'),
    MenuItem(key: TrayMenuKeys.quickAdd, label: 'Quick add\u2026'),
    MenuItem.separator(),
    MenuItem(key: TrayMenuKeys.quit, label: 'Quit Forge'),
  ],
);

/// `launch_at_startup`-backed [AutostartController]. Registers Forge to launch
/// at login (Windows registry / `~/.config/autostart` on Linux). Must be
/// [setup] once with the running executable path before use.
final class LaunchAtStartupAutostartController implements AutostartController {
  const LaunchAtStartupAutostartController();

  /// Configures the launcher with the current executable. Call once on desktop
  /// before toggling autostart.
  static void setup() {
    launchAtStartup.setup(
      appName: 'Forge',
      appPath: io.Platform.resolvedExecutable,
    );
  }

  @override
  Future<bool> isEnabled() async {
    try {
      return await launchAtStartup.isEnabled();
    } on Object {
      return false;
    }
  }

  @override
  Future<void> enable() async {
    try {
      await launchAtStartup.enable();
    } on Object {
      // Best-effort; a sandbox may deny autostart registration.
    }
  }

  @override
  Future<void> disable() async {
    try {
      await launchAtStartup.disable();
    } on Object {
      // ignore
    }
  }
}

/// The action callbacks the tray/hotkey/window-close events route to. Set by a
/// widget mounted inside the wired ProviderScope so the shell can reach the
/// Riverpod controllers without owning them.
final class DesktopShellActions {
  const DesktopShellActions({
    required this.onOpenFull,
    required this.onToggleWidget,
    required this.onQuickAdd,
    required this.onClose,
    required this.onQuit,
  });

  final Future<void> Function() onOpenFull;
  final Future<void> Function() onToggleWidget;
  final Future<void> Function() onQuickAdd;

  /// Handles a window-close request (hide-to-tray vs quit per user preference).
  final Future<void> Function() onClose;
  final Future<void> Function() onQuit;
}

/// Owns the tray listener, the global hotkey, and the window-close listener,
/// routing each event to the currently bound [DesktopShellActions].
///
/// The global summon/toggle hotkey defaults to Ctrl+Alt+T (task §6).
final class DesktopShell with TrayListener, WindowListener {
  DesktopShell({this.hotkeys = const NoopGlobalHotkeyBinder()});

  DesktopShellActions? _actions;
  bool _started = false;
  bool _hotkeyRegistered = false;

  /// The global-hotkey binder (no-op by default; see the file header note).
  final GlobalHotkeyBinder hotkeys;

  /// Binds the live action callbacks (from the widget tree).
  void bind(DesktopShellActions actions) => _actions = actions;

  void unbind() => _actions = null;

  /// Registers the tray icon+menu, the window listener, and the global hotkey.
  /// Idempotent and best-effort.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    trayManager.addListener(this);
    windowManager.addListener(this);
    try {
      await trayManager.setIcon(DesktopTrayAssets.iconPath);
      await trayManager.setToolTip('Forge');
      await trayManager.setContextMenu(buildForgeTrayMenu());
    } on Object {
      // No StatusNotifier host (headless/xvfb) — tray simply won't appear.
    }
    await _registerHotkey();
  }

  Future<void> _registerHotkey() async {
    try {
      _hotkeyRegistered = await hotkeys.register(
        () async => _dispatch((DesktopShellActions a) => a.onToggleWidget()),
      );
    } on Object {
      // Global hotkey registration can fail without a session; non-fatal.
      _hotkeyRegistered = false;
    }
  }

  /// Reconciles the global hotkey with the user's Settings preference. Enabling
  /// (re)registers Ctrl+Alt+T; disabling removes it. Best-effort and idempotent
  /// so a failed grab (e.g. Wayland) simply leaves the hotkey inactive.
  Future<void> applyHotkeyEnabled(bool enabled) async {
    if (enabled) {
      if (!_hotkeyRegistered) {
        await _registerHotkey();
      }
    } else {
      try {
        await hotkeys.unregister();
      } on Object {
        // ignore
      }
      _hotkeyRegistered = false;
    }
  }

  Future<void> stop() async {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await hotkeys.unregister();
    } on Object {
      // ignore
    }
    _hotkeyRegistered = false;
    _started = false;
  }

  // --- TrayListener ---------------------------------------------------------

  void _dispatch(Future<void> Function(DesktopShellActions actions)? action) {
    final DesktopShellActions? actions = _actions;
    if (actions != null && action != null) {
      unawaited(action(actions));
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Left click summons/toggles the widget.
    _dispatch((DesktopShellActions a) => a.onToggleWidget());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case TrayMenuKeys.openFull:
        _dispatch((DesktopShellActions a) => a.onOpenFull());
      case TrayMenuKeys.toggleWidget:
        _dispatch((DesktopShellActions a) => a.onToggleWidget());
      case TrayMenuKeys.quickAdd:
        _dispatch((DesktopShellActions a) => a.onQuickAdd());
      case TrayMenuKeys.quit:
        _dispatch((DesktopShellActions a) => a.onQuit());
    }
  }

  // --- WindowListener -------------------------------------------------------

  @override
  void onWindowClose() {
    // preventClose is on; decide hide-to-tray vs quit via the bound action.
    _dispatch((DesktopShellActions a) => a.onClose());
  }
}
