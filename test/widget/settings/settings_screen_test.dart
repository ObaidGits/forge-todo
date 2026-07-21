import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the Settings hub and its route into Life Area management
/// (R-GEN-002, NFR-A11Y-001).
void main() {
  Future<void> pump(WidgetTester tester, {String at = '/settings'}) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GoRouter router = createForgeRouter(initialLocation: at);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('given_settings_when_opened_then_shows_management_entries', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    expect(find.text('Life Areas'), findsWidgets);
    expect(find.textContaining('Version'), findsOneWidget);
  });

  testWidgets('given_settings_when_life_areas_tapped_then_navigates', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Life Areas').first);
    await tester.pumpAndSettle();
    // The Life Area management screen renders (unwired -> calm empty state).
    expect(
      find.textContaining("Life Areas aren't available yet"),
      findsOneWidget,
    );
  });

  testWidgets('given_areas_route_when_opened_directly_then_renders', (
    WidgetTester tester,
  ) async {
    await pump(tester, at: '/settings/areas');
    expect(
      find.textContaining("Life Areas aren't available yet"),
      findsOneWidget,
    );
  });
}
