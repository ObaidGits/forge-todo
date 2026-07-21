import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'habits_widget_harness.dart';

/// Widget tests for the Today habit checklist (R-HOME-001, R-HOME-003,
/// R-HABIT-006, NFR-A11Y-001).
void main() {
  late HabitsWidgetHarness harness;

  setUp(() async {
    harness = await HabitsWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_no_habits_when_opened_then_shows_neutral_empty_state', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    expect(
      find.textContaining('No habits scheduled for today'),
      findsOneWidget,
    );
  });

  testWidgets('given_scheduled_boolean_habit_when_opened_then_listed_as_open', (
    WidgetTester tester,
  ) async {
    await harness.createBooleanHabit(id: 'h-1', title: 'Meditate');
    await harness.pumpApp(tester);
    expect(find.text('Meditate'), findsOneWidget);
    // Neutral status copy, not a shaming label.
    expect(find.textContaining('Open'), findsOneWidget);
  });

  testWidgets('given_open_habit_when_checked_then_marks_done_without_leaving', (
    WidgetTester tester,
  ) async {
    await harness.createBooleanHabit(id: 'h-1', title: 'Meditate');
    await harness.pumpApp(tester);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    // Inline completion (R-HOME-003): still on the checklist, now Done.
    expect(find.text('Meditate'), findsOneWidget);
    expect(find.textContaining('Done'), findsOneWidget);
  });

  testWidgets(
    'given_checklist_when_rendered_then_control_has_accessible_name',
    (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await harness.createBooleanHabit(id: 'h-1', title: 'Meditate');
      await harness.pumpApp(tester);
      expect(find.bySemanticsLabel('Mark Meditate done'), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets('given_habit_when_skipped_then_shows_neutral_confirmation', (
    WidgetTester tester,
  ) async {
    await harness.createBooleanHabit(id: 'h-1', title: 'Meditate');
    await harness.pumpApp(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Marked as skipped'), findsOneWidget);
  });
}
