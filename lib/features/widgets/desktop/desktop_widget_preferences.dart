import 'dart:convert';

import 'package:forge/app/desktop/desktop_settings_store.dart';

/// Which tabs the desktop sticky widget shows (task §7).
enum WidgetTabs {
  today('today'),
  notes('notes'),
  both('both');

  const WidgetTabs(this.wire);

  final String wire;

  bool get showsToday => this == today || this == both;
  bool get showsNotes => this == notes || this == both;

  static WidgetTabs fromWire(String? wire) {
    for (final WidgetTabs value in WidgetTabs.values) {
      if (value.wire == wire) {
        return value;
      }
    }
    return WidgetTabs.both;
  }
}

/// The persisted, device-local preferences for the desktop "sticky widget".
///
/// This is pure data with no Flutter/plugin dependency so it round-trips
/// deterministically through the local [DesktopSettingsStore] and is fully
/// unit-testable. Values are device-local operational settings, never user
/// content and never synced (R-SYNC-002 local-only class).
final class DesktopWidgetPreferences {
  const DesktopWidgetPreferences({
    this.enabled = false,
    this.alwaysOnTop = true,
    this.startOnLogin = false,
    this.opacity = 1.0,
    this.lockPosition = false,
    this.tabs = WidgetTabs.both,
    this.hotkeyEnabled = true,
  });

  /// Whether the desktop widget feature is enabled at all. When false the tray
  /// still summons the full app but the compact sticky is unavailable.
  final bool enabled;

  /// Whether the widget floats above other windows ("display over other apps").
  /// Best-effort: limited under Wayland (see [DesktopWidgetController]).
  final bool alwaysOnTop;

  /// Whether Forge registers itself to launch at login.
  final bool startOnLogin;

  /// Widget window opacity in the inclusive range `0.3..1.0`.
  final double opacity;

  /// Whether the widget position is locked (drag disabled).
  final bool lockPosition;

  /// Which tabs to show in the compact widget.
  final WidgetTabs tabs;

  /// Whether the global summon/toggle hotkey (Ctrl+Alt+T) is registered. When
  /// false the tray and Settings still toggle the widget. Best-effort: even
  /// when true the platform (e.g. Wayland) may refuse the global grab.
  final bool hotkeyEnabled;

  /// The minimum allowed opacity so the widget never becomes invisible.
  static const double minOpacity = 0.3;

  static const DesktopWidgetPreferences defaults = DesktopWidgetPreferences();

  DesktopWidgetPreferences copyWith({
    bool? enabled,
    bool? alwaysOnTop,
    bool? startOnLogin,
    double? opacity,
    bool? lockPosition,
    WidgetTabs? tabs,
    bool? hotkeyEnabled,
  }) {
    final double next = opacity ?? this.opacity;
    return DesktopWidgetPreferences(
      enabled: enabled ?? this.enabled,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      startOnLogin: startOnLogin ?? this.startOnLogin,
      opacity: next < minOpacity
          ? minOpacity
          : next > 1.0
          ? 1.0
          : next,
      lockPosition: lockPosition ?? this.lockPosition,
      tabs: tabs ?? this.tabs,
      hotkeyEnabled: hotkeyEnabled ?? this.hotkeyEnabled,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'alwaysOnTop': alwaysOnTop,
    'startOnLogin': startOnLogin,
    'opacity': opacity,
    'lockPosition': lockPosition,
    'tabs': tabs.wire,
    'hotkeyEnabled': hotkeyEnabled,
  };

  /// Parses a persisted map, falling back to defaults for any missing or
  /// malformed field so a corrupt preference never crashes the shell.
  static DesktopWidgetPreferences fromJson(Map<String, Object?> json) {
    final Object? rawOpacity = json['opacity'];
    return DesktopWidgetPreferences(
      enabled: json['enabled'] == true,
      alwaysOnTop: json['alwaysOnTop'] != false,
      startOnLogin: json['startOnLogin'] == true,
      opacity: rawOpacity is num ? rawOpacity.toDouble() : 1.0,
      lockPosition: json['lockPosition'] == true,
      tabs: WidgetTabs.fromWire(json['tabs'] as String?),
      hotkeyEnabled: json['hotkeyEnabled'] != false,
    ).copyWith();
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopWidgetPreferences &&
      other.enabled == enabled &&
      other.alwaysOnTop == alwaysOnTop &&
      other.startOnLogin == startOnLogin &&
      other.opacity == opacity &&
      other.lockPosition == lockPosition &&
      other.tabs == tabs &&
      other.hotkeyEnabled == hotkeyEnabled;

  @override
  int get hashCode => Object.hash(
    enabled,
    alwaysOnTop,
    startOnLogin,
    opacity,
    lockPosition,
    tabs,
    hotkeyEnabled,
  );
}

/// Reads and writes [DesktopWidgetPreferences] to the local settings store.
///
/// All values live under a single JSON key so a read/modify/write cycle is
/// atomic at the store level. Persistence is best-effort; a failed write leaves
/// the in-memory intent intact and never blocks the widget.
final class DesktopWidgetPreferencesStore {
  DesktopWidgetPreferencesStore({
    required this.store,
    this.storageKey = 'desktop.widget_preferences',
  });

  final DesktopSettingsStore store;
  final String storageKey;

  Future<DesktopWidgetPreferences> load() async {
    final String? raw = await store.read(storageKey);
    if (raw == null) {
      return DesktopWidgetPreferences.defaults;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return DesktopWidgetPreferences.fromJson(decoded);
      }
    } on FormatException {
      return DesktopWidgetPreferences.defaults;
    }
    return DesktopWidgetPreferences.defaults;
  }

  Future<void> save(DesktopWidgetPreferences prefs) async {
    await store.write(storageKey, jsonEncode(prefs.toJson()));
  }
}
