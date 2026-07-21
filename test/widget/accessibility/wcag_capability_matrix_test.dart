import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

import '../goals/goals_widget_harness.dart';

/// Consolidated WCAG 2.2 AA automatable-evidence suite and the machine-checkable
/// accessibility capability-matrix verifier for task 12.3.
///
/// This suite is the in-repo half of the task 12.3 deliverable. It (a) runs the
/// automatable WCAG 2.2 AA checks — semantics name/role/state, 48 dp target
/// size, 200% text without overflow, reduced motion, keyboard operability, and
/// never-drag-only reorder, plus a controlled text-contrast check — and (b)
/// asserts the generated capability matrix stays honest: no platform is Full,
/// assistive technology is manual-required on every platform, the device-gated
/// dimensions (notification/background/widget) stay manual-required, and every
/// automatable WCAG criterion cites real in-repo evidence. Real assistive
/// technology, physical devices, and packaged-OS behavior remain MANUAL-* items
/// enumerated in `docs/evidence/accessibility-capability-matrix.v1.json` and can
/// never be produced here.
///
/// Evidence: [TEST-A11Y-CAPABILITY-MATRIX-001][V1][TASK-12.3][NFR-A11Y-001]
/// [NFR-A11Y-002][NFR-A11Y-003]
///
/// **Validates: Requirements NFR-A11Y-001, NFR-A11Y-002, NFR-A11Y-003**
void main() {
  group('WCAG 2.2 AA automatable evidence (host target)', () {
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
      'given_core_screen_when_rendered_then_meets_semantics_and_target_size '
      'guidelines (NFR-A11Y-001/002/003; SC 1.3.1, 2.5.8, 4.1.2)',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await harness.createGoal(
          title: 'Goal A',
          progressMode: GoalProgressMode.manual,
        );
        await harness.pumpApp(tester);

        // Name/role/state semantics plus 48x48 dp primary touch targets.
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      },
    );

    testWidgets(
      'given_core_screen_at_2x_text_scale_when_rendered_then_no_overflow '
      '(NFR-A11Y-001/003; SC 1.4.4, 1.4.10)',
      (WidgetTester tester) async {
        final String goalId = await harness.createGoal(
          title: 'Read twelve challenging books this year',
          outcomeMd: 'Finish a substantial book every single month',
          progressMode: GoalProgressMode.manual,
          manualProgress: 0.5,
        );
        // 200% text via TextScaler.linear(textScale) must not overflow.
        await harness.pumpApp(
          tester,
          initialLocation: '/goals/$goalId',
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        expect(find.text('50%'), findsOneWidget);
      },
    );

    testWidgets('given_reduced_motion_when_rendered_then_no_layout_exception '
        '(NFR-A11Y-001/003; SC 2.3.3)', (WidgetTester tester) async {
      final String goalId = await harness.createGoal(
        title: 'Ship the thing',
        progressMode: GoalProgressMode.manual,
        manualProgress: 0.25,
      );
      // disableAnimations mirrors the OS reduce-motion setting.
      await harness.pumpApp(
        tester,
        initialLocation: '/goals/$goalId',
        disableAnimations: true,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'given_roadmap_reorder_when_keyboard_activates_move_then_order_changes '
      '(NFR-A11Y-001/002; SC 2.1.1, 2.5.7 — never drag-only)',
      (WidgetTester tester) async {
        final String goalId = await seedRoadmap();
        await harness.pumpApp(
          tester,
          initialLocation: '/goals/$goalId/roadmap',
        );

        // Reorder always has a discrete, named, keyboard-operable alternative
        // (Move up / Move down), never drag-only.
        final Finder moveDown = find.byTooltip('Move Ownership down');
        expect(moveDown, findsOneWidget);
        expect(find.byTooltip('Move Ownership up'), findsOneWidget);
        final Finder moveDownIcon = find.descendant(
          of: moveDown,
          matching: find.byIcon(Icons.arrow_downward),
        );
        expect(moveDownIcon, findsOneWidget);
        Focus.of(tester.element(moveDownIcon)).requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        final double ownershipDy = tester.getTopLeft(find.text('Ownership')).dy;
        final double borrowingDy = tester.getTopLeft(find.text('Borrowing')).dy;
        expect(ownershipDy, greaterThan(borrowingDy));
      },
    );

    testWidgets(
      'given_controlled_text_surface_when_rendered_then_meets_text_contrast '
      '(NFR-A11Y-001; SC 1.4.3)',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.white,
              body: Center(
                child: Text(
                  'Reminder scheduled',
                  style: TextStyle(color: Color(0xFF111111), fontSize: 16),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      },
    );
  });

  group('accessibility capability matrix artifact (task 12.3)', () {
    Map<String, Object?> readMatrix() {
      final File file = File(
        'docs/evidence/accessibility-capability-matrix.v1.json',
      );
      expect(
        file.existsSync(),
        isTrue,
        reason: 'run tool/release/accessibility_capability_matrix.py generate',
      );
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }

    const List<String> dimensions = <String>[
      'notification',
      'background',
      'widget',
      'keyboard',
      'semantics',
      'assistiveTechnology',
    ];

    test('traces exactly to task 12.3 and the three accessibility NFRs', () {
      final Map<String, Object?> matrix = readMatrix();
      expect(matrix['schemaVersion'], 'forge-a11y-capability-matrix/v1');
      expect(matrix['task'], '12.3');
      expect(matrix['requirements'], <String>[
        'NFR-A11Y-001',
        'NFR-A11Y-002',
        'NFR-A11Y-003',
      ]);
    });

    test('covers all four platforms x six dimensions without Full claims', () {
      final Map<String, Object?> matrix = readMatrix();
      final List<Object?> targets = matrix['targets']! as List<Object?>;
      final Set<String> platforms = <String>{};
      for (final Object? entry in targets) {
        final Map<String, Object?> target = entry! as Map<String, Object?>;
        final String platform = target['platform']! as String;
        platforms.add(platform);

        // No platform may claim Full support.
        expect(
          target['supportClaim'],
          isNot('full'),
          reason: '$platform must not claim Full support',
        );

        final Map<String, Object?> dims =
            target['dimensions']! as Map<String, Object?>;
        expect(dims.keys.toSet(), dimensions.toSet());

        // Assistive technology can never be automated in-repo.
        final Map<String, Object?> at =
            dims['assistiveTechnology']! as Map<String, Object?>;
        expect(at['state'], 'manual-required', reason: '$platform AT');
        expect((at['manualFollowUps']! as List<Object?>), isNotEmpty);

        // Device-gated dimensions stay manual-required.
        for (final String dimension in <String>['notification', 'background']) {
          final Map<String, Object?> cell =
              dims[dimension]! as Map<String, Object?>;
          expect(
            cell['state'],
            'manual-required',
            reason: '$platform $dimension',
          );
          expect(cell['declaredDegradation'], isNotNull);
        }

        // Keyboard and semantics carry real automated in-repo evidence.
        for (final String dimension in <String>['keyboard', 'semantics']) {
          final Map<String, Object?> cell =
              dims[dimension]! as Map<String, Object?>;
          expect(
            cell['state'],
            'automated-verified',
            reason: '$platform $dimension',
          );
          expect((cell['inRepoEvidence']! as List<Object?>), isNotEmpty);
        }
      }
      expect(platforms, <String>{'android', 'ios', 'windows', 'linux'});
    });

    test('desktop widget dimension is not-applicable', () {
      final Map<String, Object?> matrix = readMatrix();
      for (final Object? entry in matrix['targets']! as List<Object?>) {
        final Map<String, Object?> target = entry! as Map<String, Object?>;
        final String platform = target['platform']! as String;
        if (platform == 'windows' || platform == 'linux') {
          final Map<String, Object?> dims =
              target['dimensions']! as Map<String, Object?>;
          final Map<String, Object?> widget =
              dims['widget']! as Map<String, Object?>;
          expect(widget['state'], 'not-applicable', reason: platform);
        }
      }
    });

    test('every automatable WCAG criterion cites in-repo evidence', () {
      final Map<String, Object?> matrix = readMatrix();
      final Map<String, Object?> catalog =
          matrix['inRepoEvidence']! as Map<String, Object?>;
      for (final Object? entry in matrix['wcagCoverage']! as List<Object?>) {
        final Map<String, Object?> row = entry! as Map<String, Object?>;
        final String automatable = row['automatable']! as String;
        final List<Object?> inRepo = row['inRepoEvidence']! as List<Object?>;
        if (automatable == 'yes') {
          expect(
            inRepo,
            isNotEmpty,
            reason: 'SC ${row['criterion']} claims automatable',
          );
          for (final Object? id in inRepo) {
            expect(catalog.containsKey(id), isTrue, reason: id.toString());
          }
        }
        if (automatable == 'no') {
          expect(
            row['manualFollowUps']! as List<Object?>,
            isNotEmpty,
            reason: 'SC ${row['criterion']} must name a manual follow-up',
          );
        }
      }
    });
  });
}
