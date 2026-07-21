import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';

import 'goals_widget_harness.dart';

/// Widget tests for the goals list (R-GOAL-001, R-GOAL-007, NFR-A11Y-001/002).
///
/// Evidence: TEST-GOAL-LIST.
void main() {
  late GoalsWidgetHarness harness;

  setUp(() async {
    harness = await GoalsWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_no_goals_when_opened_then_shows_empty_state', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    expect(
      find.text('No goals yet. Add one to connect daily work to an outcome.'),
      findsOneWidget,
    );
  });

  testWidgets('given_many_goals_when_opened_then_lists_all_without_gating', (
    WidgetTester tester,
  ) async {
    // Unlimited goals, no paid gating (R-GOAL-001): seed well beyond any free
    // tier and expect every one to be listed.
    for (int i = 0; i < 12; i += 1) {
      await harness.createGoal(
        title: 'Goal $i',
        progressMode: GoalProgressMode.manual,
      );
    }
    await harness.pumpApp(tester);
    for (int i = 0; i < 12; i += 1) {
      expect(find.text('Goal $i'), findsOneWidget);
    }
  });

  testWidgets('given_active_goal_when_archived_then_moves_and_offers_undo', (
    WidgetTester tester,
  ) async {
    await harness.createGoal(
      title: 'Ship v1',
      progressMode: GoalProgressMode.manual,
    );
    await harness.pumpApp(tester);
    expect(find.text('Ship v1'), findsOneWidget);

    await tester.tap(find.byTooltip('Archive'));
    await tester.pumpAndSettle();

    // The archived goal leaves the Active view and an Undo is offered
    // (R-GOAL-007 preserves history; the archive is reversible).
    expect(find.text('Ship v1'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);

    // Switch to Archived to confirm the goal is preserved, not deleted.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Archived'));
    await tester.pumpAndSettle();
    expect(find.text('Ship v1'), findsOneWidget);
  });

  testWidgets('given_create_dialog_when_confirmed_then_navigates_to_detail', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New goal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Run a marathon');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // Landed on the detail screen for the new goal.
    expect(find.text('Run a marathon'), findsWidgets);
    expect(find.text('Milestones · 0 of 0 done'), findsOneWidget);
  });

  testWidgets('given_list_when_rendered_then_has_accessible_names', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await harness.createGoal(
      title: 'Goal A',
      progressMode: GoalProgressMode.manual,
    );
    await harness.pumpApp(tester);
    // Archive control exposes an accessible name, not an icon-only target.
    expect(find.byTooltip('Archive'), findsOneWidget);
    handle.dispose();
  });
}
