import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/desktop_bindings.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';

/// Mounts inside the wired [ProviderScope] and connects the desktop [shell]'s
/// tray/hotkey/window-close events to the live Riverpod controllers, then starts
/// the shell (tray icon + global hotkey + window listener).
///
/// Kept as a thin binder so the plugin-driven [DesktopShell] never reaches into
/// Riverpod directly and the single engine keeps one composition root.
final class DesktopShellBinder extends ConsumerStatefulWidget {
  const DesktopShellBinder({
    required this.shell,
    required this.child,
    super.key,
  });

  final DesktopShell shell;
  final Widget child;

  @override
  ConsumerState<DesktopShellBinder> createState() => _DesktopShellBinderState();
}

class _DesktopShellBinderState extends ConsumerState<DesktopShellBinder> {
  @override
  void initState() {
    super.initState();
    widget.shell.bind(
      DesktopShellActions(
        onOpenFull: _openFull,
        onToggleWidget: _toggleWidget,
        onQuickAdd: _quickAdd,
        onClose: _close,
        onQuit: _quit,
      ),
    );
    unawaited(widget.shell.start());
    unawaited(_hydrate());
  }

  /// Loads persisted widget preferences and the last full-window geometry, then
  /// applies them. Best-effort; failures leave safe defaults.
  Future<void> _hydrate() async {
    try {
      final prefs = await ref
          .read(desktopWidgetPreferencesStoreProvider)
          .load();
      if (!mounted) {
        return;
      }
      _controller.hydratePreferences(prefs);
      // Reconcile the global hotkey with the persisted preference (start()
      // registers it by default; disable it here when the user turned it off).
      await widget.shell.applyHotkeyEnabled(prefs.hotkeyEnabled);
    } on Object {
      // ignore
    }
    try {
      await ref.read(windowStateServiceProvider).restore();
    } on Object {
      // ignore
    }
  }

  @override
  void dispose() {
    widget.shell.unbind();
    super.dispose();
  }

  DesktopWidgetController get _controller =>
      ref.read(desktopWidgetControllerProvider.notifier);

  Future<void> _openFull() async {
    await _controller.enterFullMode();
    await ref.read(trayControllerProvider).showWindow();
  }

  Future<void> _toggleWidget() => _controller.toggle();

  Future<void> _quickAdd() => _controller.requestQuickAdd();

  Future<void> _close() => ref.read(closeBehaviorServiceProvider).handleClose();

  Future<void> _quit() => ref.read(trayControllerProvider).quit();

  @override
  Widget build(BuildContext context) {
    // Live-apply Settings toggles of the global hotkey without a relaunch.
    ref.listen<bool>(
      desktopWidgetControllerProvider.select(
        (DesktopWidgetState state) => state.preferences.hotkeyEnabled,
      ),
      (bool? previous, bool next) {
        if (previous != next) {
          unawaited(widget.shell.applyHotkeyEnabled(next));
        }
      },
    );
    return widget.child;
  }
}
