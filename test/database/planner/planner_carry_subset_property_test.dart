import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

import 'planner_test_support.dart';

/// Generative property test for the factual-close accounting invariants of
/// R-PLAN-003: across randomly generated task sets and carried subsets, the one
/// immutable factual close must report eligible/completed/missed/carried counts
/// that agree with the set definitions, and — crucially — "carried" is always a
/// labeled subset of "missed" that is never double-counted, while a carried id
/// that is not a missed planned task is always rejected.
///
/// **Validates: Requirements R-PLAN-001, R-PLAN-003**
void main() {
  Future<PlanningPeriod> saveDay(PlannerHarness h, String key) async {
    await h.service.savePlanningRecord(
      commandId: h.nextCommandId('save-$key'),
      profileId: h.profileId,
      input: SavePlanningRecordInput(
        lifeAreaId: h.lifeAreaId.value,
        kind: PlanningPeriodKind.day,
        periodKey: key,
        dailyPlanMd: SectionEdit.set('plan $key'),
      ),
    );
    return (await h.reads.findByKey(
      h.profileId,
      lifeAreaId: h.lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: key,
    ))!;
  }

  for (final int seed in <int>[5, 23, 88, 314]) {
    test('[TEST-DB-PLAN-CARRY-SUBSET-PROP][MVP][TASK-5.6][R-PLAN-003] '
        'carried is a non-double-counted subset of missed across random closes '
        '(seed=$seed)', () async {
      final PlannerHarness h = await PlannerHarness.open();
      addTearDown(h.close);
      final Random random = Random(seed);

      for (int iteration = 0; iteration < 12; iteration += 1) {
        final String key =
            '2024-06-${(iteration + 1).toString().padLeft(2, '0')}';
        final PlanningPeriod day = await saveDay(h, key);

        final int taskCount = 1 + random.nextInt(8);
        final List<CloseTaskInput> tasks = <CloseTaskInput>[];
        final Set<String> eligible = <String>{};
        final Set<String> completed = <String>{};
        final Set<String> missed = <String>{};

        for (int t = 0; t < taskCount; t += 1) {
          final String id = 'it${iteration}_t$t';
          final bool cancelled = random.nextInt(6) == 0;
          final bool planned = random.nextBool();
          // Ensure every task is at least planned or due so it is meaningful.
          final bool due = !planned || random.nextBool();
          final bool done = random.nextBool();
          tasks.add(
            CloseTaskInput(
              taskId: id,
              isPlanned: planned,
              isDue: due,
              completedAtOrBeforeBoundary: done,
              cancelledBeforeClose: cancelled,
            ),
          );
          if (cancelled) {
            continue;
          }
          if (planned || due) {
            eligible.add(id);
            if (done) {
              completed.add(id);
            }
          }
          if (planned && !done) {
            missed.add(id);
          }
        }

        // Choose a random subset of the missed tasks to carry forward.
        final List<String> missedList = missed.toList()..sort();
        final Set<String> carried = <String>{
          for (final String id in missedList)
            if (random.nextBool()) id,
        };

        final Result<CommittedCommandResult> result = await h.service
            .closePeriod(
              commandId: h.nextCommandId('close-$key'),
              profileId: h.profileId,
              input: ClosePeriodInput(
                periodId: day.id.value,
                boundaryUtc: 1_000 + iteration,
                metricPolicyVersion: 1,
                tasks: tasks,
                carriedTaskIds: carried,
              ),
            );

        expect(result.failureOrNull, isNull, reason: 'valid close $key');
        final PlanningCloseEvent close = (await h.reads.closeOf(
          h.profileId,
          day.id,
        ))!;

        // Aggregate counts match the set definitions.
        expect(close.eligibleCount, eligible.length, reason: 'eligible');
        expect(close.completedCount, completed.length, reason: 'completed');
        expect(close.missedCount, missed.length, reason: 'missed');
        expect(close.carriedCount, carried.length, reason: 'carried');

        // Core R-PLAN-003 invariant: carried is a subset of missed and is
        // never counted on top of missed (no double count).
        expect(
          close.carriedCount,
          lessThanOrEqualTo(close.missedCount),
          reason: 'carried must be a subset of missed',
        );
        expect(carried.difference(missed), isEmpty);

        // Item-level: carried ids are labeled 'carried', the rest of the
        // missed set is labeled 'missed' (a partition, never both).
        final List<PlanningCloseItem> items = await h.reads.closeItemsOf(
          h.profileId,
          close.id,
        );
        final Map<String, String> status = <String, String>{
          for (final PlanningCloseItem i in items) i.entityId: i.status,
        };
        for (final String id in missed) {
          expect(
            status[id],
            carried.contains(id) ? 'carried' : 'missed',
            reason: 'status of missed task $id',
          );
        }
        for (final String id in completed) {
          expect(status[id], 'completed', reason: 'status of $id');
        }
      }
    });
  }

  test('[TEST-DB-PLAN-CARRY-SUBSET-GUARD-PROP][MVP][TASK-5.6][R-PLAN-003] '
      'carrying any non-missed task is always rejected', () async {
    final PlannerHarness h = await PlannerHarness.open();
    addTearDown(h.close);
    final Random random = Random(777);

    for (int iteration = 0; iteration < 8; iteration += 1) {
      final String key =
          '2024-07-${(iteration + 1).toString().padLeft(2, '0')}';
      final PlanningPeriod day = await saveDay(h, key);

      // A completed planned task and a due-only task: neither is "missed".
      const String completedId = 'done';
      const String dueOnlyId = 'due-open';
      final List<CloseTaskInput> tasks = const <CloseTaskInput>[
        CloseTaskInput(
          taskId: completedId,
          isPlanned: true,
          isDue: true,
          completedAtOrBeforeBoundary: true,
        ),
        CloseTaskInput(
          taskId: dueOnlyId,
          isPlanned: false,
          isDue: true,
          completedAtOrBeforeBoundary: false,
        ),
      ];
      final String badCarry = random.nextBool() ? completedId : dueOnlyId;

      final Result<CommittedCommandResult> result = await h.service.closePeriod(
        commandId: h.nextCommandId('bad-$key'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: tasks,
          carriedTaskIds: <String>{badCarry},
        ),
      );

      expect(result.failureOrNull?.code, 'planner.invalid_carry');
      // No factual close is written when the carry set is invalid.
      expect(await h.reads.closeOf(h.profileId, day.id), isNull);
    }
  });
}
