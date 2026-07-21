import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/app/desktop/window_state.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';

/// Whether the single desktop window is showing the full app or the compact
/// sticky widget (task §2). There is exactly one window/engine, so this is a
/// mode of the same window rather than a separate one — the encrypted
/// DatabaseRuntime writer lock is never contended.
enum DesktopWidgetMode { full, widget }

/// Immutable desktop-widget UI state.
final class DesktopWidgetState {
  const DesktopWidgetState({
    required this.mode,
    required this.preferences,
    this.alwaysOnTopHonored = true,
    this.activeTab = WidgetTab.today,
    this.focusAddTick = 0,
  });

  final DesktopWidgetMode mode;
  final DesktopWidgetPreferences preferences;

  /// False when the platform (e.g. Wayland) ignored the always-on-top request,
  /// so the UI can disclose that the sticky may not fully pin.
  final bool alwaysOnTopHonored;

  /// The tab shown in the compact widget.
  final WidgetTab activeTab;

  /// Monotonic counter bumped by [DesktopWidgetController.requestQuickAdd] so
  /// the view focuses its quick-add field.
  final int focusAddTick;

  bool get isWidgetMode => mode == DesktopWidgetMode.widget;

  DesktopWidgetState copyWith({
    DesktopWidgetMode? mode,
    DesktopWidgetPreferences? preferences,
    bool? alwaysOnTopHonored,
    WidgetTab? activeTab,
    int? focusAddTick,
  }) => DesktopWidgetState(
    mode: mode ?? this.mode,
    preferences: preferences ?? this.preferences,
    alwaysOnTopHonored: alwaysOnTopHonored ?? this.alwaysOnTopHonored,
    activeTab: activeTab ?? this.activeTab,
    focusAddTick: focusAddTick ?? this.focusAddTick,
  );
}

/// The compact widget's tabs.
enum WidgetTab { today, notes }

/// Orchestrates the single-window widget mode (task §2): it toggles the OS
/// window between the full titled app and a small frameless always-on-top
/// sticky, persists widget preferences, and exposes the compact view's tab and
/// quick-add focus intents.
///
/// It holds no business rules — data still flows through the reused Riverpod
/// providers (same engine) — only window/shell orchestration.
final class DesktopWidgetController extends Notifier<DesktopWidgetState> {
  DesktopWidgetController();

  DesktopWindowManager get _windowManager =>
      ref.read(desktopWindowManagerProvider);
  DesktopWidgetPreferencesStore get _preferencesStore =>
      ref.read(desktopWidgetPreferencesStoreProvider);
  WindowStateService get _windowStateService =>
      ref.read(windowStateServiceProvider);

  @override
  DesktopWidgetState build() {
    final DesktopWidgetPreferences initial = ref.watch(
      desktopWidgetInitialPreferencesProvider,
    );
    return DesktopWidgetState(
      mode: DesktopWidgetMode.full,
      preferences: initial,
      activeTab: initial.tabs.showsToday ? WidgetTab.today : WidgetTab.notes,
    );
  }

  /// Shrinks the window into the sticky widget. Captures the current full-mode
  /// geometry first so [enterFullMode] can restore it. Discloses when the
  /// platform ignored always-on-top.
  Future<void> enterWidgetMode() async {
    // Remember the full-window geometry so returning restores it exactly.
    await _windowStateService.capture();
    final DesktopWidgetPreferences prefs = state.preferences;
    final bool honored = await _windowManager.enterWidgetMode(
      WidgetWindowSpec(alwaysOnTop: prefs.alwaysOnTop, opacity: prefs.opacity),
    );
    state = state.copyWith(
      mode: DesktopWidgetMode.widget,
      alwaysOnTopHonored: honored || !prefs.alwaysOnTop,
    );
  }

  /// Expands the sticky back into the full titled window at the last remembered
  /// geometry.
  Future<void> enterFullMode() async {
    final WindowState restore =
        await _windowStateService.load() ?? WindowState.initial;
    await _windowManager.enterFullMode(restore.clampedToMinimum());
    state = state.copyWith(mode: DesktopWidgetMode.full);
  }

  /// Toggles between full and widget mode (bound to the tray + global hotkey).
  Future<void> toggle() async {
    if (state.isWidgetMode) {
      await enterFullMode();
    } else {
      await enterWidgetMode();
    }
  }

  /// Shows the sticky widget and focuses its quick-add field (tray "Quick add").
  Future<void> requestQuickAdd() async {
    if (!state.isWidgetMode) {
      await enterWidgetMode();
    }
    await _windowManager.show();
    state = state.copyWith(
      activeTab: WidgetTab.today,
      focusAddTick: state.focusAddTick + 1,
    );
  }

  /// Selects the visible tab in the compact widget.
  void selectTab(WidgetTab tab) {
    if (state.activeTab != tab) {
      state = state.copyWith(activeTab: tab);
    }
  }

  /// Adopts persisted preferences loaded from disk WITHOUT writing them back
  /// (called once on launch). Keeps the active tab valid for the tab set.
  void hydratePreferences(DesktopWidgetPreferences prefs) {
    WidgetTab tab = state.activeTab;
    if (tab == WidgetTab.today && !prefs.tabs.showsToday) {
      tab = WidgetTab.notes;
    } else if (tab == WidgetTab.notes && !prefs.tabs.showsNotes) {
      tab = WidgetTab.today;
    }
    state = state.copyWith(preferences: prefs, activeTab: tab);
  }

  /// Persists a new preferences snapshot and applies the live effects
  /// (always-on-top, opacity) when the widget is currently showing.
  Future<void> updatePreferences(DesktopWidgetPreferences prefs) async {
    await _preferencesStore.save(prefs);
    bool honored = state.alwaysOnTopHonored;
    if (state.isWidgetMode) {
      honored = await _windowManager.setAlwaysOnTop(prefs.alwaysOnTop);
      await _windowManager.setOpacity(prefs.opacity);
      honored = honored || !prefs.alwaysOnTop;
    }
    // Keep the active tab valid for the chosen tab set.
    WidgetTab tab = state.activeTab;
    if (tab == WidgetTab.today && !prefs.tabs.showsToday) {
      tab = WidgetTab.notes;
    } else if (tab == WidgetTab.notes && !prefs.tabs.showsNotes) {
      tab = WidgetTab.today;
    }
    state = state.copyWith(
      preferences: prefs,
      alwaysOnTopHonored: honored,
      activeTab: tab,
    );
  }

  /// Begins an interactive drag of the frameless widget (ignored when the
  /// position is locked).
  Future<void> startDragging() async {
    if (!state.preferences.lockPosition) {
      await _windowManager.startDragging();
    }
  }
}
