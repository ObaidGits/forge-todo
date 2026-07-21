import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';

/// Goal progress policy: manual clamping and derived topic-leaf aggregation
/// with a transparent formula surface (R-GOAL-004).
///
/// **Validates: Requirements R-GOAL-004**
void main() {
  group('given manual progress when building the surface', () {
    test('then a value inside 0..1 is preserved and exposed as computable', () {
      final GoalProgress p = GoalProgressPolicy.manual(0.42);
      expect(p.mode, GoalProgressMode.manual);
      expect(p.value, 0.42);
      expect(p.isComputable, isTrue);
      expect(p.formula, GoalProgressPolicy.manualFormula);
      // Manual mode contributes no weighted leaves.
      expect(p.eligibleCount, 0);
      expect(p.totalWeight, 0);
    });

    test('then out-of-range values clamp into 0..1', () {
      expect(GoalProgressPolicy.clampManual(-0.5), 0.0);
      expect(GoalProgressPolicy.clampManual(1.5), 1.0);
      expect(GoalProgressPolicy.clampManual(double.nan), 0.0);
    });

    test('then a null stored value is not computable', () {
      final GoalProgress p = GoalProgressPolicy.manual(null);
      expect(p.value, isNull);
      expect(p.isComputable, isFalse);
    });
  });

  group('given derived progress when aggregating topic leaves', () {
    test('then it divides completed eligible weight by eligible weight', () {
      final GoalProgress p = GoalProgressPolicy.derived(<GoalProgressLeaf>[
        GoalProgressLeaf(eligible: true, completed: true, weight: 3),
        GoalProgressLeaf(eligible: true, completed: false, weight: 1),
      ]);
      expect(p.mode, GoalProgressMode.derived);
      expect(p.value, closeTo(3 / 4, 1e-12));
      expect(p.eligibleCount, 2);
      expect(p.totalWeight, 4);
      expect(p.completedWeight, 3);
      expect(p.formula, GoalProgressPolicy.derivedFormula);
    });

    test('then a null topic weight normalizes to 1', () {
      final GoalProgress p = GoalProgressPolicy.derived(<GoalProgressLeaf>[
        GoalProgressLeaf(eligible: true, completed: true),
        GoalProgressLeaf(eligible: true, completed: false),
      ]);
      expect(p.totalWeight, 2);
      expect(p.completedWeight, 1);
      expect(p.value, closeTo(0.5, 1e-12));
    });

    test('then archived/cancelled (ineligible) leaves are excluded', () {
      final GoalProgress p = GoalProgressPolicy.derived(<GoalProgressLeaf>[
        GoalProgressLeaf(eligible: true, completed: true, weight: 2),
        GoalProgressLeaf(eligible: false, completed: true, weight: 99),
        GoalProgressLeaf(eligible: false, completed: false, weight: 99),
      ]);
      expect(p.eligibleCount, 1);
      expect(p.totalWeight, 2);
      expect(p.value, 1.0);
    });

    test('then zero eligible leaves yields no computable progress', () {
      final GoalProgress p = GoalProgressPolicy.derived(
        const <GoalProgressLeaf>[],
      );
      expect(p.value, isNull);
      expect(p.isComputable, isFalse);
      expect(p.eligibleCount, 0);
      expect(p.totalWeight, 0);
    });

    test('then a zero eligible total weight yields no computable progress', () {
      final GoalProgress p = GoalProgressPolicy.derived(<GoalProgressLeaf>[
        GoalProgressLeaf(eligible: true, completed: false, weight: 0),
        GoalProgressLeaf(eligible: true, completed: true, weight: 0),
      ]);
      expect(p.value, isNull);
      expect(p.eligibleCount, 2);
      expect(p.totalWeight, 0);
    });

    test('then a negative topic weight is rejected', () {
      expect(
        () => GoalProgressLeaf(eligible: true, completed: false, weight: -1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('given randomized topic leaves when computing derived progress', () {
    // Property: derived progress is always within 0..1, equals
    // completedWeight/totalWeight when total > 0, never double-counts
    // ineligible leaves, and is null exactly when the eligible total is 0.
    test(
      '[TEST-GOAL-PROGRESS-PROP][MVP][TASK-6.1][R-GOAL-004] '
      'derived progress stays in 0..1 and matches the transparent formula',
      () {
        const int cases = 400;
        for (int seed = 0; seed < cases; seed += 1) {
          final Random rng = Random(0x60A1 ^ seed);
          final int n = rng.nextInt(8);
          final List<GoalProgressLeaf> leaves = <GoalProgressLeaf>[];
          for (int i = 0; i < n; i += 1) {
            final bool eligible = rng.nextBool();
            final bool completed = rng.nextBool();
            final num? weight = rng.nextInt(4) == 0
                ? null // exercise null-normalization to 1
                : rng.nextInt(6); // 0..5, includes zero weights
            leaves.add(
              GoalProgressLeaf(
                eligible: eligible,
                completed: completed,
                weight: weight,
              ),
            );
          }

          num expectedTotal = 0;
          num expectedCompleted = 0;
          int expectedEligible = 0;
          for (final GoalProgressLeaf leaf in leaves) {
            if (!leaf.eligible) {
              continue;
            }
            expectedEligible += 1;
            expectedTotal += leaf.normalizedWeight;
            if (leaf.completed) {
              expectedCompleted += leaf.normalizedWeight;
            }
          }

          final GoalProgress p = GoalProgressPolicy.derived(leaves);
          expect(p.eligibleCount, expectedEligible, reason: 'seed=$seed');
          expect(p.totalWeight, expectedTotal, reason: 'seed=$seed');
          expect(p.completedWeight, expectedCompleted, reason: 'seed=$seed');
          if (expectedTotal == 0) {
            expect(p.value, isNull, reason: 'seed=$seed');
          } else {
            expect(p.value, isNotNull, reason: 'seed=$seed');
            expect(
              p.value! >= 0 && p.value! <= 1,
              isTrue,
              reason: 'seed=$seed',
            );
            expect(
              p.value,
              closeTo(expectedCompleted / expectedTotal, 1e-12),
              reason: 'seed=$seed',
            );
          }
        }
      },
    );
  });
}
