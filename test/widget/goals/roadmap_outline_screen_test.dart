import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';

import 'goals_widget_harness.dart';

/// Widget tests for the roadmap outline (R-GOAL-003, R-GOAL-004, R-GOAL-005,
/// NFR-A11Y-001/002). Reorder is keyboard/pointer-first through explicit Move
/// up/down controls — never drag-only.
///
/// Evidence: TEST-GOAL-ROADMAP.
void main() {
  late GoalsWidgetHarness harness;

  setUp(() async {
    harness = await GoalsWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  Future<String> seedGoal(WidgetTester tester) async {
    return harness.createGoal(
      title: 'Learn Rust',
      progressMode: GoalProgressMode.derived,
    );
  }

  testWidgets('given_no_roadmap_when_opened_then_offers_create', (
    WidgetTester tester,
  ) async {
    final String goalId = await seedGoal(tester);
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

    expect(find.text('Create roadmap'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Create roadmap'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My path');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('My path'), findsWidgets);
    expect(find.text('Add section'), findsOneWidget);
  });

  testWidgets('given_roadmap_when_rendered_then_shows_sections_and_topics', (
    WidgetTester tester,
  ) async {
    final String goalId = await seedGoal(tester);
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(
      roadmapId,
      title: 'Fundamentals',
    );
    await harness.addTopic(sectionId, title: 'Ownership', weight: 2);
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

    expect(find.text('Fundamentals'), findsOneWidget);
    expect(find.text('Ownership'), findsOneWidget);
    // The topic's weight is shown in its metadata line.
    expect(find.textContaining('Weight 2'), findsOneWidget);
    // Per-section presentation aggregation chip is shown alongside the section.
    expect(find.byType(Chip), findsWidgets);
  });

  testWidgets('given_two_topics_when_move_down_then_order_swaps', (
    WidgetTester tester,
  ) async {
    final String goalId = await seedGoal(tester);
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(roadmapId);
    await harness.addTopic(sectionId, title: 'First');
    await harness.addTopic(sectionId, title: 'Second');
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

    // Keyboard/pointer reorder alternative to drag (R-GOAL-005): move "First"
    // down and confirm the persisted order changed via the read repository.
    await tester.tap(find.byTooltip('Move First down'));
    await tester.pumpAndSettle();

    final Roadmap roadmap = (await harness.roadmapReads.findByGoal(
      harness.profileId,
      GoalId(goalId),
    ))!;
    final RoadmapSection section = (await harness.roadmapReads.sectionsOf(
      harness.profileId,
      roadmap.id,
    )).first;
    final List<RoadmapTopic> topics = await harness.roadmapReads
        .topicsOfSection(harness.profileId, section.id);
    expect(topics.map((RoadmapTopic t) => t.title).toList(), <String>[
      'Second',
      'First',
    ]);
  });

  testWidgets('given_topic_when_checkbox_toggled_then_progress_updates', (
    WidgetTester tester,
  ) async {
    final String goalId = await seedGoal(tester);
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(roadmapId);
    await harness.addTopic(sectionId, title: 'Ownership', weight: 1);
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

    // Initially 0% (roadmap card and the section aggregation chip both show
    // it, since the single topic is eligible with weight 1 but not completed).
    expect(find.text('Not started — no computable progress'), findsNothing);
    expect(find.text('0%'), findsWidgets);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsWidgets);
  });

  testWidgets('given_move_controls_when_rendered_then_have_named_actions', (
    WidgetTester tester,
  ) async {
    final String goalId = await seedGoal(tester);
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(
      roadmapId,
      title: 'Section A',
    );
    await harness.addTopic(sectionId, title: 'Topic A');
    await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

    // Move alternatives are labelled per item so they are never drag-only or
    // icon-only (NFR-A11Y-001/002; R-GOAL-005).
    expect(find.byTooltip('Move Section A up'), findsOneWidget);
    expect(find.byTooltip('Move Section A down'), findsOneWidget);
    expect(find.byTooltip('Move Topic A up'), findsOneWidget);
    expect(find.byTooltip('Move Topic A down'), findsOneWidget);
  });
}
