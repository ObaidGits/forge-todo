import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the command palette (R-SEARCH-004, NFR-A11Y-001).
void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GoRouter router = createForgeRouter(initialLocation: '/today');
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

  Future<void> openPalette(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Command palette'));
    await tester.pumpAndSettle();
  }

  testWidgets('given_shell_when_palette_opened_then_lists_commands', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await openPalette(tester);
    // Top-of-list commands are built and visible in the palette.
    expect(find.text('Search everything'), findsOneWidget);
    expect(find.text('Go to Tasks'), findsOneWidget);
  });

  testWidgets('given_palette_when_filtered_then_narrows_list', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await openPalette(tester);
    await tester.enterText(find.byType(TextField).last, 'habit');
    await tester.pumpAndSettle();
    expect(find.text('Go to Habits'), findsOneWidget);
    expect(find.text('Go to Tasks'), findsNothing);
  });

  testWidgets('given_palette_when_no_match_then_shows_empty', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await openPalette(tester);
    await tester.enterText(find.byType(TextField).last, 'zzzzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching commands'), findsOneWidget);
  });

  testWidgets('given_palette_when_command_selected_then_navigates', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await openPalette(tester);
    // Filter so the target command is built, then activate it.
    await tester.enterText(find.byType(TextField).last, 'notes');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to Notes'));
    await tester.pumpAndSettle();
    // The palette closed.
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('given_shell_when_ctrl_shift_p_pressed_then_opens_palette', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Search everything'), findsOneWidget);
  });
}
