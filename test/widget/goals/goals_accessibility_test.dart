import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

import 'goals_widget_harness.dart';

/// Accessibility coverage for the goal and roadmap screens
/// (NFR-A11Y-001/002/003). Automated checks assert labelled tap targets,
/// minimum tap-target size, and layout integrity under large text; a full
/// WCAG 2.2 AA claim additionally requires the manual assistive-technology
/// study archived as `MANUAL-A11Y-CRITICAL`, which these checks complement but
/// cannot replace.
///
/// **Validates: Requirements NFR-A11Y-001, NFR-A11Y-002, NFR-A11Y-003**
void main() {
  late GoalsWidgetHarness harness;

  setUp(() async {
    harness = await GoalsWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  Future<String> seedRoadmap() async {
    final String goalId = await harness.createGoal(
      title: 'Learn Rust',
      progressMode: GoalProgressMode.derived,
    );
    final String roadmapId = await harness.createRoadmap(goalId);
    final String sectionId = await harness.addSection(
      roadmapId,
      title: 'Fundamentals',
    );
    await harness.addTopic(sectionId, title: 'Ownership', weight: 2);
    await harness.addTopic(
      sectionId,
      title: 'Borrowing',
      weight: 1,
      status: RoadmapTopicStatus.completed,
    );
    return goalId;
  }

  testWidgets(
    'given_goal_list_when_rendered_then_meets_tap_target_and_label_guidelines',
    (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await harness.createGoal(
        title: 'Goal A',
        progressMode: GoalProgressMode.manual,
      );
      await harness.pumpApp(tester);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    },
  );

  testWidgets(
    'given_roadmap_outline_when_rendered_then_meets_tap_target_and_label_'
    'guidelines',
    (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final String goalId = await seedRoadmap();
      await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    },
  );

  testWidgets(
    'given_goal_detail_at_2x_text_scale_when_rendered_then_no_overflow',
    (WidgetTester tester) async {
      final String goalId = await harness.createGoal(
        title: 'Read twelve challenging books this year',
        outcomeMd: 'Finish a substantial book every single month',
        progressMode: GoalProgressMode.manual,
        manualProgress: 0.5,
      );
      // A 2× text scale must not overflow the layout (NFR-A11Y-003). The pump
      // would surface any RenderFlex overflow as a test failure.
      await harness.pumpApp(
        tester,
        initialLocation: '/goals/$goalId',
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Formula: manual(clamped 0..1)'), findsOneWidget);
    },
  );

  testWidgets(
    'given_roadmap_outline_at_2x_text_scale_when_rendered_then_no_overflow',
    (WidgetTester tester) async {
      final String goalId = await seedRoadmap();
      await harness.pumpApp(
        tester,
        initialLocation: '/goals/$goalId/roadmap',
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Fundamentals'), findsOneWidget);
      expect(find.text('Ownership'), findsOneWidget);
      // Named, keyboard-activatable reorder alternatives remain present at
      // large text (never drag-only): NFR-A11Y-001/002; R-GOAL-005.
      expect(find.byTooltip('Move Ownership up'), findsOneWidget);
      expect(find.byTooltip('Move Ownership down'), findsOneWidget);
    },
  );

  testWidgets(
    'given_roadmap_outline_when_keyboard_activates_move_then_order_changes',
    (WidgetTester tester) async {
      final String goalId = await seedRoadmap();
      await harness.pumpApp(tester, initialLocation: '/goals/$goalId/roadmap');

      // The move-down control is a real focusable, keyboard-activatable button
      // (not a drag-only affordance). Focus the underlying IconButton and
      // activate it with the keyboard to confirm keyboard operability
      // (NFR-A11Y-002; R-GOAL-005).
      final Finder moveDown = find.byTooltip('Move Ownership down');
      expect(moveDown, findsOneWidget);
      final Finder moveDownIcon = find.descendant(
        of: moveDown,
        matching: find.byIcon(Icons.arrow_downward),
      );
      expect(moveDownIcon, findsOneWidget);
      // The nearest Focus ancestor of the icon is the IconButton's own node.
      Focus.of(tester.element(moveDownIcon)).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // 'Ownership' moved after 'Borrowing' — the outline reflects the
      // keyboard-driven reorder.
      final double ownershipDy = tester.getTopLeft(find.text('Ownership')).dy;
      final double borrowingDy = tester.getTopLeft(find.text('Borrowing')).dy;
      expect(ownershipDy, greaterThan(borrowingDy));
    },
  );
}
