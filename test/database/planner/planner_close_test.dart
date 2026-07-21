import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_close_adjustment_kind.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

import 'planner_test_support.dart';

/// Immutable factual close inputs and metric-ready audit semantics
/// (R-PLAN-003, R-HOME-004, R-HABIT-005).
void main() {
  late PlannerHarness h;

  setUp(() async {
    h = await PlannerHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<PlanningPeriod> saveDay(String key) async {
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

  test(
    '[TEST-DB-PLAN-CLOSE-COUNTS][MVP][TASK-5.4][R-PLAN-003,R-HOME-004] '
    'the factual close records eligible/completed/missed/carried counts',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-01');
      final Result<CommittedCommandResult> result = await h.service.closePeriod(
        commandId: h.nextCommandId('close-1'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 2_000_000,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            // planned + completed
            CloseTaskInput(
              taskId: 'task-done',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: true,
            ),
            // planned + incomplete -> missed
            CloseTaskInput(
              taskId: 'task-missed-1',
              isPlanned: true,
              isDue: false,
              completedAtOrBeforeBoundary: false,
            ),
            CloseTaskInput(
              taskId: 'task-missed-2',
              isPlanned: true,
              isDue: false,
              completedAtOrBeforeBoundary: false,
            ),
            // due but not planned + incomplete -> incomplete (not missed)
            CloseTaskInput(
              taskId: 'task-due-open',
              isPlanned: false,
              isDue: true,
              completedAtOrBeforeBoundary: false,
            ),
            // cancelled before close -> excluded from eligible set
            CloseTaskInput(
              taskId: 'task-cancelled',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: false,
              cancelledBeforeClose: true,
            ),
          ],
          carriedTaskIds: <String>{'task-missed-1'},
        ),
      );

      expect(result.failureOrNull, isNull);
      final PlanningCloseEvent close = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;
      expect(close.eligibleCount, 4); // done, missed-1, missed-2, due-open
      expect(close.completedCount, 1);
      expect(close.missedCount, 2);
      expect(close.carriedCount, 1); // labeled subset of missed
      expect(close.eligibleRootHash, isNotEmpty);
      expect(close.completedRootHash, isNotEmpty);

      final List<PlanningCloseItem> items = await h.reads.closeItemsOf(
        h.profileId,
        close.id,
      );
      final Map<String, String> status = <String, String>{
        for (final PlanningCloseItem i in items) i.entityId: i.status,
      };
      expect(status['task-done'], 'completed');
      expect(status['task-missed-1'], 'carried');
      expect(status['task-missed-2'], 'missed');
      expect(status['task-due-open'], 'incomplete');
      expect(status['task-cancelled'], 'cancelled');
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-BOUNDARY][MVP][TASK-5.4][R-PLAN-003] '
    'a planned task incomplete at the planning-day boundary is missed',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-02');
      await h.service.closePeriod(
        commandId: h.nextCommandId('close-b'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 5_000_000,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 'late',
              isPlanned: true,
              isDue: true,
              // Completed only after the boundary => still missed at close.
              completedAtOrBeforeBoundary: false,
            ),
          ],
        ),
      );

      final PlanningCloseEvent close = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;
      expect(close.boundaryUtc, 5_000_000);
      expect(close.missedCount, 1);
      expect(close.completedCount, 0);
    },
  );

  test('[TEST-DB-PLAN-CLOSE-CARRY-GUARD][MVP][TASK-5.4][R-PLAN-003] '
      'a carried id that is not a missed planned task is rejected', () async {
    final PlanningPeriod day = await saveDay('2024-06-03');
    final Result<CommittedCommandResult> result = await h.service.closePeriod(
      commandId: h.nextCommandId('close-guard'),
      profileId: h.profileId,
      input: ClosePeriodInput(
        periodId: day.id.value,
        boundaryUtc: 1,
        metricPolicyVersion: 1,
        tasks: const <CloseTaskInput>[
          CloseTaskInput(
            taskId: 'task-complete',
            isPlanned: true,
            isDue: true,
            completedAtOrBeforeBoundary: true,
          ),
        ],
        carriedTaskIds: <String>{'task-complete'},
      ),
    );

    expect(result.failureOrNull?.code, 'planner.invalid_carry');
    expect(await h.reads.closeOf(h.profileId, day.id), isNull);
  });

  test(
    '[TEST-DB-PLAN-CLOSE-ONE-PER-PERIOD][MVP][TASK-5.4][R-PLAN-003] '
    'exactly one immutable factual close per period; a second is rejected',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-04');
      final ClosePeriodInput input = ClosePeriodInput(
        periodId: day.id.value,
        boundaryUtc: 1,
        metricPolicyVersion: 1,
        tasks: const <CloseTaskInput>[
          CloseTaskInput(
            taskId: 't1',
            isPlanned: true,
            isDue: true,
            completedAtOrBeforeBoundary: true,
          ),
        ],
      );
      final first = await h.service.closePeriod(
        commandId: h.nextCommandId('c-first'),
        profileId: h.profileId,
        input: input,
      );
      expect(first.failureOrNull, isNull);

      // A different command trying to close again is rejected.
      final second = await h.service.closePeriod(
        commandId: h.nextCommandId('c-second'),
        profileId: h.profileId,
        input: input,
      );
      expect(second.failureOrNull?.code, 'planner.already_closed');
      expect(
        await h.scalar(
          'SELECT COUNT(*) AS c FROM planning_close_events WHERE period_id = ?',
          <Object?>[day.id.value],
        ),
        1,
      );
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-IDEMPOTENT][MVP][TASK-5.4][R-PLAN-003,R-GEN-005] '
    'retrying the same close command replays its receipt without a new close',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-05');
      final ClosePeriodInput input = ClosePeriodInput(
        periodId: day.id.value,
        boundaryUtc: 1,
        metricPolicyVersion: 1,
        tasks: const <CloseTaskInput>[
          CloseTaskInput(
            taskId: 't1',
            isPlanned: true,
            isDue: true,
            completedAtOrBeforeBoundary: true,
          ),
        ],
      );
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-idem'),
        profileId: h.profileId,
        input: input,
      );
      final Result<CommittedCommandResult> replay = await h.service.closePeriod(
        commandId: h.nextCommandId('c-idem'),
        profileId: h.profileId,
        input: input,
      );

      expect(replay.valueOrNull?.replayed, isTrue);
      expect(
        await h.scalar(
          'SELECT COUNT(*) AS c FROM planning_close_events WHERE period_id = ?',
          <Object?>[day.id.value],
        ),
        1,
      );
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-SOURCE-CORRECTION][MVP][TASK-5.4][R-PLAN-003,R-HABIT-005] '
    'a later source correction is appended and the factual close is unchanged',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-06');
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-src'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 'task-missed',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: false,
            ),
          ],
        ),
      );
      final PlanningCloseEvent before = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;

      final Result<CommittedCommandResult> result = await h.service
          .appendSourceCorrection(
            commandId: h.nextCommandId('src-1'),
            profileId: h.profileId,
            input: SourceCorrectionInput(
              periodId: day.id.value,
              affectedEntityType: 'task',
              affectedEntityId: 'task-missed',
              affectedMetric: 'task_completion',
              priorClassification: 'missed',
              currentClassification: 'completed',
              delta: 1,
              reason: 'late completion recorded',
            ),
          );

      expect(result.failureOrNull, isNull);
      final List<PlanningCloseAdjustment> adjustments = await h.reads
          .adjustmentsOf(h.profileId, before.id);
      expect(adjustments, hasLength(1));
      expect(
        adjustments.single.kind,
        PlanningCloseAdjustmentKind.sourceCorrection,
      );
      expect(adjustments.single.priorClassification, 'missed');
      expect(adjustments.single.currentClassification, 'completed');

      // The immutable factual close is unchanged (never rewritten).
      final PlanningCloseEvent after = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;
      expect(after.id, before.id);
      expect(after.missedCount, before.missedCount);
      expect(after.completedCount, before.completedCount);
      expect(after.eligibleRootHash, before.eligibleRootHash);
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-POLICY-RECOMPUTE][MVP][TASK-5.4][R-PLAN-003] '
    'a newer-policy recomputation is a separate derived record, not a new close',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-07');
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-pol'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 't1',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: true,
            ),
          ],
        ),
      );
      final PlanningCloseEvent close = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;
      expect(close.metricPolicyVersion, 1);

      final Result<CommittedCommandResult> result = await h.service
          .appendPolicyRecomputation(
            commandId: h.nextCommandId('pol-2'),
            profileId: h.profileId,
            input: PolicyRecomputationInput(
              periodId: day.id.value,
              metricPolicyVersion: 2,
              derivedSummaryJson: '{"task_completion":1.0}',
              affectedMetric: 'task_completion',
            ),
          );

      expect(result.failureOrNull, isNull);
      // Still exactly one factual close, still recorded under policy v1.
      expect(
        await h.scalar(
          'SELECT COUNT(*) AS c FROM planning_close_events WHERE period_id = ?',
          <Object?>[day.id.value],
        ),
        1,
      );
      final List<PlanningCloseAdjustment> adjustments = await h.reads
          .adjustmentsOf(h.profileId, close.id);
      expect(adjustments, hasLength(1));
      expect(
        adjustments.single.kind,
        PlanningCloseAdjustmentKind.policyRecomputation,
      );
      expect(adjustments.single.metricPolicyVersion, 2);
      expect(adjustments.single.derivedRootHash, isNotNull);
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-ADJUSTMENT-APPEND-ONLY][MVP][TASK-5.4][R-PLAN-003] '
    'source and policy adjustments accumulate as append-only audit records',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-08');
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-acc'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 'task-a',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: false,
            ),
          ],
        ),
      );
      final PlanningCloseEvent close = (await h.reads.closeOf(
        h.profileId,
        day.id,
      ))!;

      await h.service.appendSourceCorrection(
        commandId: h.nextCommandId('acc-src'),
        profileId: h.profileId,
        input: SourceCorrectionInput(
          periodId: day.id.value,
          affectedEntityType: 'task',
          affectedEntityId: 'task-a',
          affectedMetric: 'task_completion',
          priorClassification: 'missed',
          currentClassification: 'completed',
          delta: 1,
        ),
      );
      await h.service.appendPolicyRecomputation(
        commandId: h.nextCommandId('acc-pol'),
        profileId: h.profileId,
        input: PolicyRecomputationInput(
          periodId: day.id.value,
          metricPolicyVersion: 2,
          derivedSummaryJson: '{"task_completion":1.0}',
        ),
      );

      final List<PlanningCloseAdjustment> adjustments = await h.reads
          .adjustmentsOf(h.profileId, close.id);
      expect(adjustments, hasLength(2));
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-HABIT-ITEMS][MVP][TASK-5.4][R-HOME-004] '
    'habit occurrences are captured as close items alongside tasks',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-09');
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-habit'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 't1',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: true,
            ),
          ],
          habits: const <CloseHabitInput>[
            CloseHabitInput(occurrenceId: 'occ-1', status: 'completed'),
            CloseHabitInput(occurrenceId: 'occ-2', status: 'missed'),
          ],
        ),
      );

      expect(
        await h.scalar(
          'SELECT COUNT(*) AS c FROM planning_close_items '
          "WHERE entity_type = 'habit_occurrence'",
        ),
        2,
      );
    },
  );

  test(
    '[TEST-DB-PLAN-CLOSE-DB-INVARIANT][MVP][TASK-5.4][R-PLAN-003] '
    'the database rejects a duplicate factual close row for a period',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-10');
      await h.service.closePeriod(
        commandId: h.nextCommandId('c-inv'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
        ),
      );

      // A raw second insert violates the unique (profile_id, period_id) index.
      await expectLater(
        h.db.customStatement(
          'INSERT INTO planning_close_events '
          '(id, profile_id, period_id, closed_at_utc, boundary_utc, '
          'metric_policy_version, source_commit_seq, eligible_count, '
          'completed_count, missed_count, carried_count, eligible_root_hash, '
          'completed_root_hash, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'close-dup',
            h.profileId.value,
            day.id.value,
            0,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            'x',
            'y',
            0,
          ],
        ),
        throwsA(isA<Object>()),
      );
    },
  );
}
