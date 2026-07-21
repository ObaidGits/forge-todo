import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/window_state.dart';

/// Unit tests for window-state persistence and restore (ux-design §9).
void main() {
  group('WindowState', () {
    test('given_state_when_json_roundtrip_then_preserves_fields', () {
      const WindowState state = WindowState(
        width: 1400,
        height: 900,
        x: 120,
        y: 64,
        maximized: true,
      );
      final WindowState? parsed = WindowState.fromJson(state.toJson());
      expect(parsed, state);
    });

    test('given_no_position_when_json_roundtrip_then_position_null', () {
      const WindowState state = WindowState(width: 1000, height: 700);
      final WindowState? parsed = WindowState.fromJson(state.toJson());
      expect(parsed, state);
      expect(parsed!.x, isNull);
      expect(parsed.y, isNull);
    });

    test('given_missing_size_when_fromJson_then_null', () {
      expect(WindowState.fromJson(<String, Object?>{'x': 1}), isNull);
    });

    test('given_below_minimum_when_clamped_then_raised_to_minimum', () {
      const WindowState small = WindowState(width: 400, height: 300);
      final WindowState clamped = small.clampedToMinimum();
      expect(clamped.width, WindowState.minWidth);
      expect(clamped.height, WindowState.minHeight);
    });
  });

  group('WindowStateService', () {
    late InMemoryDesktopSettingsStore store;
    late InMemoryWindowController controller;
    late WindowStateService service;

    setUp(() {
      store = InMemoryDesktopSettingsStore();
      controller = InMemoryWindowController();
      service = WindowStateService(store: store, controller: controller);
    });

    test('given_no_stored_state_when_restore_then_applies_initial', () async {
      final WindowState restored = await service.restore();
      expect(restored, WindowState.initial);
      expect(controller.lastApplied, WindowState.initial);
    });

    test('given_persisted_state_when_restore_then_applies_it', () async {
      const WindowState saved = WindowState(
        width: 1500,
        height: 950,
        x: 10,
        y: 20,
      );
      await service.persist(saved);

      final WindowState restored = await service.restore();
      expect(restored, saved);
      expect(controller.lastApplied, saved);
    });

    test('given_capture_when_persisted_then_load_returns_state', () async {
      const WindowState current = WindowState(width: 1200, height: 800, x: 5);
      controller = InMemoryWindowController(current);
      service = WindowStateService(store: store, controller: controller);

      final WindowState captured = await service.capture();
      expect(captured, current);
      expect(await service.load(), current);
    });

    test('given_below_minimum_when_restore_then_clamped', () async {
      await service.persist(const WindowState(width: 200, height: 150));
      final WindowState restored = await service.restore();
      expect(restored.width, WindowState.minWidth);
      expect(restored.height, WindowState.minHeight);
    });

    test('given_corrupt_stored_value_when_load_then_null', () async {
      await store.write('desktop.window_state', 'not-json');
      expect(await service.load(), isNull);
    });
  });
}
