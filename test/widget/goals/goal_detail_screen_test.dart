import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

import 'goals_widget_harness.dart';

/// Widget tests for the goal detail screen (R-GOAL-002, R-GOAL-004, R-GOAL-006,
/// R-GOAL-007, NFR-A11Y-001/002/003).
///
/// Evidence: TEST-GOAL-DETAIL.
void main() {
  late GoalsWidgetHarness harness;

  setUp(() async {
    harness = await GoalsWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_manual_goal_when_opened_then_shows_transparent_formula', (
    WidgetTester tester,
  ) async {
    final String goalId = await harness.createGoal(
      title: 'Read 12 books',
      outcomeMd: 'Finish a book a month',
      progressMode: GoalProgressMode.manual,
      manualProgress: 0.5,
    );
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId');

    expect(find.text('Read 12 books'), findsWidgets);
    expect(find.text('Finish a book a month'), findsOneWidget);
    // The transparent progress formula (R-GOAL-004): formula + eligible count +
    // total weight are all visible.
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Formula: manual(clamped 0..1)'), findsOneWidget);
    expect(find.textContaining('eligible topic'), findsOneWidget);
    expect(find.textContaining('Completed weight'), findsOneWidget);
  });

  testWidgets('given_derived_goal_with_topics_then_shows_derived_formula', (
    WidgetTester tester,
  ) async {
    final String goalId = await harness.createGoal(
      title: 'Learn Rust',
      progressMode: GoalProgressMode.derived,
    );
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(roadmapId);
    await harness.addTopic(sectionId, title: 'A', weight: 1);
    await harness.addTopic(
      sectionId,
      title: 'B',
      weight: 1,
      status: RoadmapTopicStatus.completed,
    );
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId');

    // 1 of 2 eligible weight completed => 50%, derived formula visible.
    expect(
      find.text(
        'Formula: completed_eligible_topic_weight / eligible_topic_weight',
      ),
      findsOneWidget,
    );
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('2 eligible topics'), findsOneWidget);
  });

  testWidgets('given_milestone_when_completed_then_shows_celebration', (
    WidgetTester tester,
  ) async {
    final String goalId = await harness.createGoal(
      title: 'Ship it',
      progressMode: GoalProgressMode.manual,
    );
    await harness.addMilestone(goalId, title: 'Alpha release');
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId');

    expect(find.text('Milestones · 0 of 1 done'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // A subtle, dismissible celebration appears (R-GOAL-006).
    expect(find.text('Milestone reached: Alpha release'), findsWidgets);
    expect(find.text('Milestones · 1 of 1 done'), findsOneWidget);

    // Dismissible.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Milestone reached: Alpha release'), findsNothing);
  });

  testWidgets(
    'given_reduced_motion_when_milestone_completed_then_no_animated_switcher',
    (WidgetTester tester) async {
      final String goalId = await harness.createGoal(
        title: 'Ship it',
        progressMode: GoalProgressMode.manual,
      );
      await harness.addMilestone(goalId, title: 'Beta');
      await harness.pumpApp(
        tester,
        initialLocation: '/goals/$goalId',
        disableAnimations: true,
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      // With reduced motion the celebration renders statically: no
      // AnimatedSwitcher inside the celebration banner subtree.
      expect(find.text('Milestone reached: Beta'), findsWidgets);
      final Finder celebration = find.byKey(
        const ValueKey<String>('goal-milestone-celebration'),
      );
      expect(celebration, findsOneWidget);
      expect(
        find.descendant(
          of: celebration,
          matching: find.byType(AnimatedSwitcher),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('given_goal_when_marked_achieved_then_status_updates', (
    WidgetTester tester,
  ) async {
    final String goalId = await harness.createGoal(
      title: 'Finish thesis',
      progressMode: GoalProgressMode.manual,
    );
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId');
    await tester.tap(find.widgetWithText(FilledButton, 'Mark achieved'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Mark achieved'), findsNothing);
    expect(find.text('Achieved'), findsWidgets);
  });
}
