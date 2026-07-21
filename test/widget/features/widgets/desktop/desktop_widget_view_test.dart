import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_view.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the compact desktop sticky widget. It renders with the
/// default (unwired) providers, so the Today/Notes tabs show calm empty states
/// and both quick-entry fields are present and keyboard-focusable.
void main() {
  Future<DesktopWidgetController> pump(WidgetTester tester) async {
    final NoopDesktopWindowManager window = NoopDesktopWindowManager();
    late DesktopWidgetController controller;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWindowManagerProvider.overrideWithValue(window),
          desktopSettingsStoreProvider.overrideWithValue(
            InMemoryDesktopSettingsStore(),
          ),
          desktopWidgetInitialPreferencesProvider.overrideWithValue(
            const DesktopWidgetPreferences(enabled: true),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              controller = ref.read(desktopWidgetControllerProvider.notifier);
              return const Scaffold(body: DesktopWidgetView());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('given_both_tabs_when_shown_then_today_and_notes_present', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    // Default (unwired) providers show the calm Today empty hint + add field.
    expect(find.text('Add a task\u2026'), findsOneWidget);
  });

  testWidgets('given_notes_tab_selected_then_shows_jot_field', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Jot a note\u2026'), findsOneWidget);
  });

  testWidgets('given_notes_only_pref_then_no_tab_bar', (
    WidgetTester tester,
  ) async {
    final DesktopWidgetController controller = await pump(tester);
    await controller.updatePreferences(
      const DesktopWidgetPreferences(enabled: true, tabs: WidgetTabs.notes),
    );
    await tester.pumpAndSettle();
    // With a single tab the tab bar collapses; only the Notes surface shows.
    expect(find.text('Jot a note\u2026'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
  });

  testWidgets('given_header_when_shown_then_has_controls', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    expect(find.byTooltip('Open full app'), findsOneWidget);
    expect(find.byTooltip('Hide widget'), findsOneWidget);
  });
}
