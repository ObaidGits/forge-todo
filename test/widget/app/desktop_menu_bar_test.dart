import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the desktop application menu bar (ux-design §9,
/// NFR-A11Y-001, NFR-A11Y-003). The menu bar forks no logic — it drives the
/// existing routes and shell actions.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onQuit,
    String initialLocation = '/today',
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GoRouter router = createForgeRouter(
      initialLocation: initialLocation,
      showMenuBar: true,
      onRequestQuit: onQuit,
    );
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

  testWidgets('given_desktop_when_shell_built_then_menu_titles_present', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    expect(find.widgetWithText(MenuBar, 'File'), findsOneWidget);
    expect(find.widgetWithText(MenuBar, 'Edit'), findsOneWidget);
    expect(find.widgetWithText(MenuBar, 'View'), findsOneWidget);
    expect(find.widgetWithText(MenuBar, 'Navigate'), findsOneWidget);
    expect(find.widgetWithText(MenuBar, 'Help'), findsOneWidget);
  });

  testWidgets('given_navigate_menu_when_item_tapped_then_navigates', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(SubmenuButton, 'Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Habits'));
    await tester.pumpAndSettle();
    // The habits route is now active in the shell app bar.
    expect(find.widgetWithText(AppBar, 'Habits'), findsOneWidget);
  });

  testWidgets('given_file_menu_when_quit_tapped_then_invokes_quit', (
    WidgetTester tester,
  ) async {
    bool quit = false;
    await pump(tester, onQuit: () => quit = true);
    await tester.tap(find.widgetWithText(SubmenuButton, 'File'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Quit Forge'));
    await tester.pumpAndSettle();
    expect(quit, isTrue);
  });

  testWidgets('given_help_menu_when_about_tapped_then_shows_about_dialog', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(SubmenuButton, 'Help'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'About Forge'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDialog), findsOneWidget);
  });

  testWidgets('given_help_menu_when_shortcuts_tapped_then_lists_shortcuts', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(SubmenuButton, 'Help'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Keyboard shortcuts'));
    await tester.pumpAndSettle();
    // The dialog lists the newly documented Select-all shortcut.
    expect(find.text('Select all — Ctrl or Command + A'), findsOneWidget);
  });

  testWidgets('given_no_desktop_flag_when_built_then_no_menu_bar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GoRouter router = createForgeRouter(showMenuBar: false);
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
    expect(find.byType(MenuBar), findsNothing);
  });
}
