import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/planner/domain/planner_policies.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// Pure planner policy tests: period-key derivation, factual-close counts,
/// the "missed" definition, carried-subset invariants, and root-hash
/// determinism (R-PLAN-001, R-PLAN-003, R-HOME-004).
void main() {
  group('period key derivation', () {
    test('[TEST-UNIT-PLAN-KEY-DAY][MVP][TASK-5.4][R-PLAN-001] '
        'a day key is the ISO date', () {
      expect(
        PlannerPolicies.keyFor(PlanningPeriodKind.day, LocalDate(2024, 6, 1)),
        '2024-06-01',
      );
    });

    test('[TEST-UNIT-PLAN-KEY-MONTH][MVP][TASK-5.4][R-PLAN-001] '
        'a month key is YYYY-MM', () {
      expect(
        PlannerPolicies.keyFor(
          PlanningPeriodKind.month,
          LocalDate(2024, 6, 15),
        ),
        '2024-06',
      );
    });

    test('[TEST-UNIT-PLAN-KEY-WEEK][MVP][TASK-5.4][R-PLAN-001] '
        'a week key uses the ISO-8601 week number', () {
      // 2024-06-01 is a Saturday in ISO week 22.
      expect(
        PlannerPolicies.keyFor(PlanningPeriodKind.week, LocalDate(2024, 6, 1)),
        '2024-W22',
      );
      // 2021-01-01 (Friday) belongs to ISO week 53 of 2020.
      expect(PlannerPolicies.weekKey(LocalDate(2021, 1, 1)), '2020-W53');
      // 2024-01-01 (Monday) is ISO week 1 of 2024.
      expect(PlannerPolicies.weekKey(LocalDate(2024, 1, 1)), '2024-W01');
    });
  });

  group('factual close counts', () {
    test(
      '[TEST-UNIT-PLAN-CLOSE-EX][MVP][TASK-5.4][R-PLAN-003,R-HOME-004] '
      'eligible is planned ∪ due minus cancelled; missed is planned incomplete',
      () {
        final CloseTaskCounts counts =
            PlannerPolicies.computeTaskClose(const <CloseTaskFact>[
              CloseTaskFact(
                entityId: 'done',
                isPlanned: true,
                isDue: true,
                completedAtOrBeforeBoundary: true,
              ),
              CloseTaskFact(
                entityId: 'missed',
                isPlanned: true,
                isDue: false,
                completedAtOrBeforeBoundary: false,
              ),
              CloseTaskFact(
                entityId: 'due-open',
                isPlanned: false,
                isDue: true,
                completedAtOrBeforeBoundary: false,
              ),
              CloseTaskFact(
                entityId: 'cancelled',
                isPlanned: true,
                isDue: true,
                completedAtOrBeforeBoundary: false,
                cancelledBeforeClose: true,
              ),
              CloseTaskFact(
                entityId: 'noise',
                isPlanned: false,
                isDue: false,
                completedAtOrBeforeBoundary: false,
              ),
            ]);

        expect(counts.eligible, 3);
        expect(counts.completed, 1);
        expect(counts.missed, 1);
        expect(counts.carried, 0);
      },
    );

    test('[TEST-UNIT-PLAN-CARRY-GUARD][MVP][TASK-5.4][R-PLAN-003] '
        'carrying a non-missed task is rejected', () {
      expect(
        () => PlannerPolicies.computeTaskClose(
          const <CloseTaskFact>[
            CloseTaskFact(
              entityId: 'done',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: true,
            ),
          ],
          carriedEntityIds: <String>{'done'},
        ),
        throwsFormatException,
      );
    });

    test('[TEST-UNIT-PLAN-ROOT-HASH][MVP][TASK-5.4][R-INSIGHT-004] '
        'the root hash is order-independent and set-sensitive', () {
      expect(
        PlannerPolicies.rootHash(<String>['b', 'a', 'c']),
        PlannerPolicies.rootHash(<String>['c', 'b', 'a']),
      );
      expect(
        PlannerPolicies.rootHash(<String>['a', 'b']),
        isNot(PlannerPolicies.rootHash(<String>['a', 'b', 'c'])),
      );
      // De-duplicates: the same set hashes identically.
      expect(
        PlannerPolicies.rootHash(<String>['a', 'a', 'b']),
        PlannerPolicies.rootHash(<String>['a', 'b']),
      );
    });
  });

  group('factual close invariants (property-based)', () {
    // Generative check: for any random mix of task facts and a carried subset
    // drawn from the missed set, the derived counts satisfy R-PLAN-003:
    //   * eligible = |planned ∪ due, minus cancelled|
    //   * completed ≤ eligible, missed ≤ eligible
    //   * carried ⊆ missed (never double-counted)
    //   * each item is classified exactly once
    test('[TEST-UNIT-PLAN-CLOSE-PROP][MVP][TASK-5.4][R-PLAN-003] '
        'derived close counts are internally consistent for random inputs', () {
      const int cases = 300;
      for (int c = 0; c < cases; c += 1) {
        final Random rng = Random(0xB0A7 + c);
        final int n = rng.nextInt(12);
        final List<CloseTaskFact> facts = <CloseTaskFact>[];
        final Set<String> missedIds = <String>{};
        int expectedEligible = 0;
        int expectedCompleted = 0;
        for (int i = 0; i < n; i += 1) {
          final String id = 't$i';
          final bool planned = rng.nextBool();
          final bool due = rng.nextBool();
          final bool cancelled = rng.nextInt(5) == 0;
          final bool completed = rng.nextBool();
          facts.add(
            CloseTaskFact(
              entityId: id,
              isPlanned: planned,
              isDue: due,
              completedAtOrBeforeBoundary: completed,
              cancelledBeforeClose: cancelled,
            ),
          );
          if (cancelled) {
            continue;
          }
          final bool eligible = planned || due;
          if (!eligible) {
            continue;
          }
          expectedEligible += 1;
          if (completed) {
            expectedCompleted += 1;
          } else if (planned) {
            missedIds.add(id);
          }
        }

        // Choose a random carried subset of the missed ids.
        final List<String> missedList = missedIds.toList()..sort();
        final Set<String> carried = <String>{
          for (final String id in missedList)
            if (rng.nextBool()) id,
        };

        final CloseTaskCounts counts = PlannerPolicies.computeTaskClose(
          facts,
          carriedEntityIds: carried,
        );

        expect(counts.eligible, expectedEligible, reason: 'case $c eligible');
        expect(
          counts.completed,
          expectedCompleted,
          reason: 'case $c completed',
        );
        expect(counts.missed, missedIds.length, reason: 'case $c missed');
        expect(counts.carried, carried.length, reason: 'case $c carried');
        // carried ⊆ missed
        expect(counts.carried <= counts.missed, isTrue);
        expect(counts.completed <= counts.eligible, isTrue);
        expect(counts.missed <= counts.eligible, isTrue);
        // Every fact is classified exactly once.
        expect(counts.items.length, facts.length, reason: 'case $c items');
        // Carried items are a labeled subset of missed items.
        final Iterable<String> carriedItems = counts.items
            .where((ClassifiedCloseItem it) => it.carried)
            .map((ClassifiedCloseItem it) => it.fact.entityId);
        expect(carriedItems.toSet(), carried, reason: 'case $c carried set');
      }
    });
  });
}
