import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/planner/domain/planner_policies.dart';

/// Metric policy v1 is the single authoritative, versioned interpretation
/// composed into the Daily Summary (R-HOME-004, R-PLAN-003, R-HABIT-007).
///
/// The set-union semantics are exercised against the planner's authoritative
/// `PlannerPolicies.computeTaskClose` — metric policy v1 reuses that
/// computation rather than forking it — while the ratio, label, and
/// policy-version stability are exercised here directly.
void main() {
  group(
    '[TEST-INSIGHT-METRIC-RATIO][MVP][TASK-8.1][R-HOME-004] MetricRatio',
    () {
      test('a zero denominator yields no data, not 0%', () {
        const MetricRatio empty = MetricRatio.empty();
        expect(empty.hasData, isFalse);
        expect(empty.ratio, isNull);
      });

      test('a positive denominator yields the transparent fraction', () {
        final MetricRatio ratio = MetricRatio(numerator: 3, denominator: 4);
        expect(ratio.hasData, isTrue);
        expect(ratio.ratio, 0.75);
      });

      test('a numerator larger than the denominator is rejected', () {
        expect(
          () => MetricRatio(numerator: 5, denominator: 4),
          throwsFormatException,
        );
      });

      test('negative counts are rejected', () {
        expect(
          () => MetricRatio(numerator: -1, denominator: 4),
          throwsFormatException,
        );
      });
    },
  );

  group('[TEST-INSIGHT-METRIC-VERSION][MVP][TASK-8.1][R-PLAN-003,R-HABIT-007] '
      'policy version label', () {
    test('policy number 1 renders the stable v1 label', () {
      expect(MetricPolicyV1.label(1), 'metric-policy-v1');
      expect(MetricPolicyV1.version, 'metric-policy-v1');
      expect(MetricPolicyV1.number, 1);
    });

    test(
      'a newer policy renders its own label so it never masquerades as v1',
      () {
        expect(MetricPolicyV1.label(2), 'metric-policy-v2');
        expect(MetricPolicyV1.label(1), isNot(MetricPolicyV1.label(2)));
      },
    );

    test('an invalid policy version is rejected', () {
      expect(() => MetricPolicyV1.label(0), throwsFormatException);
    });
  });

  // Property: task completion under metric policy v1 counts the deduplicated
  // set-union of planned and due tasks exactly once. Building the eligible set
  // from two independent id sets, the eligible count is always the size of the
  // union — a task in both sets is never double-counted — and the completed
  // count never exceeds it.
  //
  // **Validates: Requirements R-HOME-004, R-PLAN-003**
  group('[TEST-INSIGHT-SET-UNION-PROP][MVP][TASK-8.1][R-HOME-004,R-PLAN-003] '
      'set-union dedup', () {
    List<CloseTaskFact> factsFor({
      required Set<String> planned,
      required Set<String> due,
      Set<String> completed = const <String>{},
      Set<String> cancelled = const <String>{},
    }) {
      final Set<String> all = <String>{...planned, ...due};
      return <CloseTaskFact>[
        for (final String id in all)
          CloseTaskFact(
            entityId: id,
            isPlanned: planned.contains(id),
            isDue: due.contains(id),
            completedAtOrBeforeBoundary: completed.contains(id),
            cancelledBeforeClose: cancelled.contains(id),
          ),
      ];
    }

    test('a task that is both planned and due is counted once', () {
      final CloseTaskCounts counts = PlannerPolicies.computeTaskClose(
        factsFor(
          planned: <String>{'a', 'b'},
          due: <String>{'b', 'c'},
          completed: <String>{'b'},
        ),
      );
      // Union {a,b,c} = 3 eligible, not 4.
      expect(counts.eligible, 3);
      expect(counts.completed, 1);
    });

    test('eligible always equals the size of the planned-due union', () {
      for (final int seed in <int>[1, 7, 42, 256, 9999]) {
        final Random random = Random(seed);
        for (int i = 0; i < 200; i += 1) {
          final Set<String> planned = <String>{
            for (int j = 0; j < random.nextInt(6); j += 1)
              'p${random.nextInt(8)}',
          };
          final Set<String> due = <String>{
            for (int j = 0; j < random.nextInt(6); j += 1)
              'p${random.nextInt(8)}',
          };
          final Set<String> union = <String>{...planned, ...due};
          // Complete a random subset of the eligible ids.
          final Set<String> completed = <String>{
            for (final String id in union)
              if (random.nextBool()) id,
          };

          final CloseTaskCounts counts = PlannerPolicies.computeTaskClose(
            factsFor(planned: planned, due: due, completed: completed),
          );

          // Counted exactly once: eligible is the union size.
          expect(counts.eligible, union.length);
          // Completed never exceeds eligible and matches the completed subset.
          expect(counts.completed, completed.length);
          expect(counts.completed, lessThanOrEqualTo(counts.eligible));
          // The eligible root hash is order-independent over the union.
          expect(counts.eligibleRootHash, PlannerPolicies.rootHash(union));
        }
      }
    });

    test('a cancelled task is excluded from the eligible union', () {
      final CloseTaskCounts counts = PlannerPolicies.computeTaskClose(
        factsFor(
          planned: <String>{'a', 'b'},
          due: <String>{'b', 'c'},
          cancelled: <String>{'b'},
        ),
      );
      // {a,c} eligible; the cancelled 'b' is dropped from both sets' union.
      expect(counts.eligible, 2);
    });
  });
}
