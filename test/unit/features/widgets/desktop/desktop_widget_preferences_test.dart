import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';

/// Unit tests for the desktop-widget preference value object and its store.
void main() {
  group('DesktopWidgetPreferences', () {
    test('given_default_when_read_then_safe_defaults', () {
      const DesktopWidgetPreferences prefs = DesktopWidgetPreferences.defaults;
      expect(prefs.enabled, isFalse);
      expect(prefs.alwaysOnTop, isTrue);
      expect(prefs.startOnLogin, isFalse);
      expect(prefs.opacity, 1.0);
      expect(prefs.lockPosition, isFalse);
      expect(prefs.tabs, WidgetTabs.both);
      expect(prefs.hotkeyEnabled, isTrue);
    });

    test('given_values_when_round_tripped_then_equal', () {
      const DesktopWidgetPreferences prefs = DesktopWidgetPreferences(
        enabled: true,
        alwaysOnTop: false,
        startOnLogin: true,
        opacity: 0.6,
        lockPosition: true,
        tabs: WidgetTabs.notes,
        hotkeyEnabled: false,
      );
      final DesktopWidgetPreferences parsed = DesktopWidgetPreferences.fromJson(
        prefs.toJson(),
      );
      expect(parsed, prefs);
      expect(parsed.hotkeyEnabled, isFalse);
    });

    test('given_out_of_range_opacity_when_copied_then_clamped', () {
      expect(
        const DesktopWidgetPreferences().copyWith(opacity: 0.05).opacity,
        DesktopWidgetPreferences.minOpacity,
      );
      expect(
        const DesktopWidgetPreferences().copyWith(opacity: 2.0).opacity,
        1.0,
      );
    });

    test('given_malformed_json_when_parsed_then_falls_back', () {
      final DesktopWidgetPreferences parsed = DesktopWidgetPreferences.fromJson(
        <String, Object?>{'opacity': 'nope', 'tabs': 'garbage'},
      );
      expect(parsed.opacity, 1.0);
      expect(parsed.tabs, WidgetTabs.both);
    });

    test('given_tabs_when_queried_then_report_visibility', () {
      expect(WidgetTabs.today.showsToday, isTrue);
      expect(WidgetTabs.today.showsNotes, isFalse);
      expect(WidgetTabs.notes.showsNotes, isTrue);
      expect(WidgetTabs.both.showsToday, isTrue);
      expect(WidgetTabs.both.showsNotes, isTrue);
    });
  });

  group('DesktopWidgetPreferencesStore', () {
    test('given_no_value_when_loaded_then_defaults', () async {
      final DesktopWidgetPreferencesStore store = DesktopWidgetPreferencesStore(
        store: InMemoryDesktopSettingsStore(),
      );
      expect(await store.load(), DesktopWidgetPreferences.defaults);
    });

    test('given_saved_when_reloaded_then_persists', () async {
      final InMemoryDesktopSettingsStore kv = InMemoryDesktopSettingsStore();
      final DesktopWidgetPreferencesStore store = DesktopWidgetPreferencesStore(
        store: kv,
      );
      const DesktopWidgetPreferences prefs = DesktopWidgetPreferences(
        enabled: true,
        opacity: 0.7,
        tabs: WidgetTabs.today,
      );
      await store.save(prefs);
      expect(await store.load(), prefs);
    });
  });
}
