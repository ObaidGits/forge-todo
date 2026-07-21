import 'dart:convert';

import 'package:forge/app/desktop/desktop_settings_store.dart';

/// A restorable desktop window geometry (ux-design §9 "remembered widths per
/// window", desktop minimum 900×600).
///
/// Coordinates and sizes are logical pixels. The value is pure data with no
/// Flutter or plugin dependency so it round-trips deterministically through the
/// local settings store and is fully unit-testable.
final class WindowState {
  const WindowState({
    required this.width,
    required this.height,
    this.x,
    this.y,
    this.maximized = false,
  });

  final double width;
  final double height;

  /// Top-left position in logical pixels, or null to let the OS place it.
  final double? x;
  final double? y;
  final bool maximized;

  /// The documented desktop minimum usable size (ux-design §3).
  static const double minWidth = 900;
  static const double minHeight = 600;

  /// A conservative default used on first launch.
  static const WindowState initial = WindowState(width: 1280, height: 832);

  /// Returns a copy clamped to the documented minimum usable size so a restored
  /// or reported geometry can never shrink the window below a usable bound.
  WindowState clampedToMinimum() => WindowState(
    width: width < minWidth ? minWidth : width,
    height: height < minHeight ? minHeight : height,
    x: x,
    y: y,
    maximized: maximized,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'width': width,
    'height': height,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    'maximized': maximized,
  };

  /// Parses a persisted map. Returns null when required fields are missing or
  /// malformed so the caller can fall back to a default rather than crash.
  static WindowState? fromJson(Map<String, Object?> json) {
    final Object? width = json['width'];
    final Object? height = json['height'];
    if (width is! num || height is! num) {
      return null;
    }
    final Object? x = json['x'];
    final Object? y = json['y'];
    return WindowState(
      width: width.toDouble(),
      height: height.toDouble(),
      x: x is num ? x.toDouble() : null,
      y: y is num ? y.toDouble() : null,
      maximized: json['maximized'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowState &&
      other.width == width &&
      other.height == height &&
      other.x == x &&
      other.y == y &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(width, height, x, y, maximized);

  @override
  String toString() =>
      'WindowState(${width}x$height @ ($x,$y) maximized=$maximized)';
}

/// The desktop window control surface. This is the integration boundary over a
/// concrete window plugin (e.g. window_manager); the real binding requires a
/// live desktop session and is a MANUAL-* follow-up. The abstraction lets the
/// persistence orchestration be tested with a fake.
abstract interface class WindowController {
  /// Applies a restored [state] to the OS window.
  Future<void> apply(WindowState state);

  /// Reads the current OS window geometry.
  Future<WindowState> current();
}

/// Persists and restores window geometry across launches using the local
/// [DesktopSettingsStore] (ux-design §9). Not synced.
final class WindowStateService {
  WindowStateService({
    required this.store,
    required this.controller,
    this.storageKey = 'desktop.window_state',
  });

  final DesktopSettingsStore store;
  final WindowController controller;
  final String storageKey;

  /// Reads the stored geometry, or null when none/invalid.
  Future<WindowState?> load() async {
    final String? raw = await store.read(storageKey);
    if (raw == null) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return WindowState.fromJson(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Restores the persisted geometry onto the window. Returns the applied state,
  /// or [WindowState.initial] when nothing valid was stored. Restored geometry
  /// is clamped to the usable minimum.
  Future<WindowState> restore() async {
    final WindowState state =
        (await load())?.clampedToMinimum() ?? WindowState.initial;
    await controller.apply(state);
    return state;
  }

  /// Persists [state] durably (clamped to the usable minimum).
  Future<void> persist(WindowState state) async {
    await store.write(
      storageKey,
      jsonEncode(state.clampedToMinimum().toJson()),
    );
  }

  /// Captures the current OS geometry and persists it. Called on move/resize
  /// (debounced by the caller) and on close.
  Future<WindowState> capture() async {
    final WindowState state = await controller.current();
    await persist(state);
    return state;
  }
}
