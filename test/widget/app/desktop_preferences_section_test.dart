import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/presentation/desktop_preferences_section.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the Settings ▸ Desktop close-behavior control (ux-design
/// §9, NFR-A11Y-001/003).
void main() {
  Future<CloseBehaviorService> pump(
    WidgetTester tester,
    DesktopSettingsStore store,
  ) async {
    late CloseBehaviorService service;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopSettingsStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              service = ref.read(closeBehaviorServiceProvider);
              // The Desktop section now includes the sticky-widget controls, so
              // it is taller than the harness viewport; host it in a scroll view
              // (as the real Settings ListView does) to avoid a spurious
              // overflow during the test.
              return const Scaffold(
                body: SingleChildScrollView(
                  child: DesktopPreferencesSection(forceShow: true),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('given_default_when_shown_then_quit_selected', (
    WidgetTester tester,
  ) async {
    await pump(tester, InMemoryDesktopSettingsStore());
    expect(find.text('Quit Forge'), findsOneWidget);
    expect(find.text('Keep running in the system tray'), findsOneWidget);
  });

  testWidgets('given_tray_option_tapped_then_persists_tray_behavior', (
    WidgetTester tester,
  ) async {
    final InMemoryDesktopSettingsStore store = InMemoryDesktopSettingsStore();
    final CloseBehaviorService service = await pump(tester, store);

    await tester.tap(find.text('Keep running in the system tray'));
    await tester.pumpAndSettle();

    expect(await service.current(), CloseBehavior.minimizeToTray);
  });

  testWidgets('given_non_desktop_and_not_forced_then_hidden', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DesktopPreferencesSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // On the (non-desktop) test host the section collapses to nothing.
    expect(find.text('When I close the window'), findsNothing);
  });
}
