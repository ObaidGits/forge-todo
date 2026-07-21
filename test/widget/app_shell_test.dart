import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/forge_app.dart';
import 'package:go_router/go_router.dart';

void main() {
  const AppConfig config = AppConfig(
    environment: ForgeEnvironment.production,
    releaseChannel: ReleaseChannel.nightly,
    buildRevision: 'test-revision',
  );
  const String noteId = '01890f3e-7b8a-7cc2-8b34-123456789abc';

  testWidgets('compact shell keeps primary actions visible and accessible', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ForgeApp(config: config));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Today'), findsWidgets);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byTooltip('Quick capture'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  testWidgets('desktop search shortcut navigates without pointer input', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createForgeRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(ForgeApp(config: config, router: router));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/search');
    expect(tester.takeException(), isNull);
  });

  testWidgets('shortcut help is keyboard discoverable and dismissible', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ForgeApp(config: config));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('Keyboard shortcuts'), findsWidgets);
    expect(find.textContaining('Ctrl or Command + K'), findsOneWidget);
    expect(find.textContaining('Ctrl or Command + Shift + N'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('new-note shortcut navigates without pointer input', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createForgeRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(ForgeApp(config: config, router: router));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/notes');
    expect(tester.takeException(), isNull);
  });
  testWidgets('opaque detail route restores only safe route state', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createForgeRouter(
      initialLocation: '/notes/$noteId',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ForgeApp(config: config, router: router));
    await tester.pumpAndSettle();

    expect(find.text('Notes'), findsWidgets);
    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.text('Notes'), findsWidgets);
    expect(find.text(noteId), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid identifier shows a localized non-reflective error', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createForgeRouter(
      initialLocation: '/notes/private-note-title',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ForgeApp(config: config, router: router));
    await tester.pumpAndSettle();

    expect(find.text('This link cannot be opened'), findsOneWidget);
    expect(find.textContaining('private-note-title'), findsNothing);
    expect(find.text('Return to Today'), findsOneWidget);
  });

  testWidgets('two hundred percent text reflows to the compact shell', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const ForgeApp(config: config));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
