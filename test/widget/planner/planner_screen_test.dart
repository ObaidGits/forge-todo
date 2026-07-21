import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

import 'planner_widget_harness.dart';

/// Widget tests for the Planner tab (R-PLAN-001, R-PLAN-004,
/// NFR-A11Y-001/003).
///
/// The Planner tab renders the current planning day's daily record — the three
/// named free-text sections — instead of the placeholder, seeds their fields
/// from the persisted record, and saves create-or-update edits durably.
void main() {
  late PlannerWidgetHarness harness;

  setUp(() async {
    harness = await PlannerWidgetHarness.open(
      initialUtc: DateTime.utc(2024, 6, 15, 9),
    );
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_no_record_when_opened_then_shows_empty_daily_sections', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);

    // The three named sections render as labelled fields, and the current
    // planning day is shown (never the "not available yet" placeholder).
    expect(find.text('Daily plan'), findsWidgets);
    expect(find.text('Morning plan'), findsOneWidget);
    expect(find.text('Evening reflection'), findsOneWidget);
    expect(find.text('Planning day 2024-06-15'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save plan'), findsOneWidget);
  });

  testWidgets('given_existing_record_when_opened_then_seeds_section_text', (
    WidgetTester tester,
  ) async {
    await harness.seedDaily(
      periodKey: '2024-06-15',
      morningPlanMd: 'Ship the planner screen',
      eveningReflectionMd: 'Made steady progress',
    );
    await harness.pumpApp(tester);

    expect(find.text('Ship the planner screen'), findsOneWidget);
    expect(find.text('Made steady progress'), findsOneWidget);
  });

  testWidgets('given_edits_when_saved_then_record_persists', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Morning plan'),
      'Deep work block',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save plan'));
    await tester.pumpAndSettle();

    expect(find.text('Plan saved'), findsOneWidget);

    // The durable record now carries the edited section.
    final record = await harness.reads.findByKey(
      harness.profileId,
      lifeAreaId: harness.lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: '2024-06-15',
    );
    expect(record, isNotNull);
    expect(record!.morningPlanMd, 'Deep work block');
  });
}
