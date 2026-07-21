import 'package:forge/app/desktop/window_state.dart';

/// A live desktop-widget window geometry request.
final class WidgetWindowSpec {
  const WidgetWindowSpec({
    this.width = 320,
    this.height = 420,
    this.alwaysOnTop = true,
    this.opacity = 1.0,
    this.skipTaskbar = false,
  });

  final double width;
  final double height;
  final bool alwaysOnTop;
  final double opacity;
  final bool skipTaskbar;
}

/// The desktop window control surface used by the sticky-widget controller.
///
/// This is the integration boundary over `window_manager`; the real binding
/// requires a live desktop session and is guarded by platform. The abstraction
/// lets widget-mode orchestration be unit-tested with a fake and keeps the
/// plugin out of mobile/test builds.
abstract interface class DesktopWindowManager {
  /// Shrinks the window into a small, frameless, (optionally) always-on-top
  /// sticky using [spec]. Returns false when the platform could not fully honor
  /// the request (e.g. always-on-top under Wayland) so callers can disclose it.
  Future<bool> enterWidgetMode(WidgetWindowSpec spec);

  /// Restores the normal titled, resizable window to [restore] geometry.
  Future<void> enterFullMode(WindowState restore);

  /// Sets always-on-top. Returns false when the platform ignored it (Wayland).
  Future<bool> setAlwaysOnTop(bool value);

  /// Sets window opacity in `0..1` (best-effort; ignored where unsupported).
  Future<void> setOpacity(double opacity);

  /// Begins an interactive drag of the frameless widget window.
  Future<void> startDragging();

  /// Shows and focuses the window.
  Future<void> show();

  /// Hides the window (used for hide-to-tray).
  Future<void> hide();

  /// Whether the window is currently visible.
  Future<bool> isVisible();

  /// Reads the current OS window geometry.
  Future<WindowState> currentState();
}

/// A no-op window manager used on mobile, in tests, and headless. Records the
/// last requested widget spec so orchestration can be asserted.
final class NoopDesktopWindowManager implements DesktopWindowManager {
  NoopDesktopWindowManager({this.alwaysOnTopSupported = true});

  /// Simulated platform capability: false models Wayland's ignored pin.
  final bool alwaysOnTopSupported;

  WidgetWindowSpec? lastWidgetSpec;
  bool enteredFullMode = false;
  bool? lastAlwaysOnTop;
  double? lastOpacity;
  bool visible = true;

  @override
  Future<bool> enterWidgetMode(WidgetWindowSpec spec) async {
    lastWidgetSpec = spec;
    visible = true;
    return alwaysOnTopSupported || !spec.alwaysOnTop;
  }

  @override
  Future<void> enterFullMode(WindowState restore) async {
    enteredFullMode = true;
    visible = true;
  }

  @override
  Future<bool> setAlwaysOnTop(bool value) async {
    lastAlwaysOnTop = value;
    return alwaysOnTopSupported || !value;
  }

  @override
  Future<void> setOpacity(double opacity) async => lastOpacity = opacity;

  @override
  Future<void> startDragging() async {}

  @override
  Future<void> show() async => visible = true;

  @override
  Future<void> hide() async => visible = false;

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<WindowState> currentState() async => WindowState.initial;
}
