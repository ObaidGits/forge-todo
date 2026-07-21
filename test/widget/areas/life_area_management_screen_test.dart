import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';

import 'areas_widget_harness.dart';

/// Widget tests for the Life Area management screen (R-GEN-002, NFR-A11Y-001).
void main() {
  late AreasWidgetHarness harness;

  setUp(() async {
    harness = await AreasWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  Future<void> seed(String name, {bool makeDefault = false}) async {
    await harness.commandService.create(
      commandId: harness.nextCommandId(),
      profileId: harness.profileId,
      input: CreateLifeAreaInput(name: name, makeDefault: makeDefault),
    );
  }

  testWidgets('given_no_areas_when_opened_then_shows_empty_state', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    expect(find.textContaining('No Life Areas yet'), findsOneWidget);
  });

  testWidgets('given_areas_when_opened_then_listed', (
    WidgetTester tester,
  ) async {
    await seed('Career');
    await seed('Health');
    await harness.pumpApp(tester);
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Health'), findsOneWidget);
  });

  testWidgets('given_default_area_when_opened_then_shows_default_badge', (
    WidgetTester tester,
  ) async {
    await seed('Personal', makeDefault: true);
    await harness.pumpApp(tester);
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('given_add_button_when_area_created_then_appears', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await tester.tap(find.byTooltip('Add Life Area'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'Finance');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Finance'), findsOneWidget);
  });

  testWidgets('given_area_when_move_control_rendered_then_has_accessible_name', (
    WidgetTester tester,
  ) async {
    await seed('Career');
    await seed('Health');
    await harness.pumpApp(tester);
    // Reorder controls expose accessible names via tooltips: the first area can
    // move down; the second can move up.
    expect(find.byTooltip('Move Career down'), findsOneWidget);
    expect(find.byTooltip('Move Health up'), findsOneWidget);
  });

  testWidgets('given_second_area_when_moved_up_then_order_changes', (
    WidgetTester tester,
  ) async {
    await seed('Career');
    await seed('Health');
    await harness.pumpApp(tester);

    await tester.tap(find.byTooltip('Move Health up'));
    await tester.pumpAndSettle();

    final List<String> ordered = (await harness.query.list(
      harness.profileId,
    )).map((LifeAreaSummary a) => a.name).toList();
    expect(ordered, <String>['Health', 'Career']);
  });

  testWidgets('given_area_when_archived_via_menu_then_shows_archived_badge', (
    WidgetTester tester,
  ) async {
    await seed('Finance');
    await harness.pumpApp(tester);

    await tester.tap(find.byTooltip('More actions for Finance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
  });

  testWidgets('given_default_area_when_archived_then_shows_blocking_message', (
    WidgetTester tester,
  ) async {
    await seed('Personal', makeDefault: true);
    await harness.pumpApp(tester);

    await tester.tap(find.byTooltip('More actions for Personal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("default Life Area can't be archived"),
      findsOneWidget,
    );
  });
}
