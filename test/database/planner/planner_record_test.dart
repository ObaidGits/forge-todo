import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

import 'planner_test_support.dart';

/// Area-scoped planning records, named daily sections, and the one-record model
/// (R-PLAN-001, R-PLAN-004, R-GEN-002).
void main() {
  group('given a fresh planner store', () {
    late PlannerHarness h;

    setUp(() async {
      h = await PlannerHarness.open(secondArea: true);
    });

    tearDown(() async {
      await h.close();
    });

    test(
      '[TEST-DB-PLAN-RECORD-DAILY][MVP][TASK-5.4][R-PLAN-001,R-PLAN-004] '
      'a daily record stores the named morning/daily/evening sections',
      () async {
        final Result<CommittedCommandResult> result = await h.service
            .savePlanningRecord(
              commandId: h.nextCommandId('day-1'),
              profileId: h.profileId,
              input: SavePlanningRecordInput(
                lifeAreaId: h.lifeAreaId.value,
                kind: PlanningPeriodKind.day,
                periodKey: '2024-06-01',
                morningPlanMd: SectionEdit.set('# Morning\nShip 5.4.'),
                dailyPlanMd: SectionEdit.set('- review'),
                eveningReflectionMd: SectionEdit.set('Solid focus.'),
                eveningPromptsJson: SectionEdit.set(
                  '{"prompts":["wins","blockers"],"skippable":true}',
                ),
              ),
            );

        expect(result.failureOrNull, isNull);
        final PlanningPeriod? record = await h.reads.findByKey(
          h.profileId,
          lifeAreaId: h.lifeAreaId,
          kind: PlanningPeriodKind.day,
          periodKey: '2024-06-01',
        );
        expect(record, isNotNull);
        expect(record!.morningPlanMd, '# Morning\nShip 5.4.');
        expect(record.dailyPlanMd, '- review');
        expect(record.eveningReflectionMd, 'Solid focus.');
        expect(record.eveningPromptsJson, contains('skippable'));
        // Aggregate sections stay null for a day record (one-record model).
        expect(record.planIntentionMd, isNull);
        expect(record.reflectionMd, isNull);
      },
    );

    test(
      '[TEST-DB-PLAN-RECORD-WEEK][MVP][TASK-5.4][R-PLAN-001] '
      'a weekly record stores plan/intention and reflection, not daily sections',
      () async {
        await h.service.savePlanningRecord(
          commandId: h.nextCommandId('week-1'),
          profileId: h.profileId,
          input: SavePlanningRecordInput(
            lifeAreaId: h.lifeAreaId.value,
            kind: PlanningPeriodKind.week,
            periodKey: '2024-W22',
            planIntentionMd: SectionEdit.set('Finish planner wave.'),
            reflectionMd: SectionEdit.set('On track.'),
          ),
        );

        final PlanningPeriod? record = await h.reads.findByKey(
          h.profileId,
          lifeAreaId: h.lifeAreaId,
          kind: PlanningPeriodKind.week,
          periodKey: '2024-W22',
        );
        expect(record!.planIntentionMd, 'Finish planner wave.');
        expect(record.reflectionMd, 'On track.');
        expect(record.morningPlanMd, isNull);
        expect(record.dailyPlanMd, isNull);
        expect(record.eveningReflectionMd, isNull);
      },
    );

    test(
      '[TEST-DB-PLAN-RECORD-UPSERT][MVP][TASK-5.4][R-PLAN-001] '
      'saving the same composite key updates the single record in place',
      () async {
        await h.service.savePlanningRecord(
          commandId: h.nextCommandId('m-1'),
          profileId: h.profileId,
          input: SavePlanningRecordInput(
            lifeAreaId: h.lifeAreaId.value,
            kind: PlanningPeriodKind.month,
            periodKey: '2024-06',
            planIntentionMd: SectionEdit.set('v1'),
          ),
        );
        await h.service.savePlanningRecord(
          commandId: h.nextCommandId('m-2'),
          profileId: h.profileId,
          input: SavePlanningRecordInput(
            lifeAreaId: h.lifeAreaId.value,
            kind: PlanningPeriodKind.month,
            periodKey: '2024-06',
            reflectionMd: SectionEdit.set('done'),
          ),
        );

        // Exactly one row for the composite key; the unchanged section survived.
        expect(
          await h.scalar(
            'SELECT COUNT(*) AS c FROM planning_periods '
            'WHERE profile_id = ? AND life_area_id = ? AND kind = ? '
            'AND period_key = ?',
            <Object?>[
              h.profileId.value,
              h.lifeAreaId.value,
              'month',
              '2024-06',
            ],
          ),
          1,
        );
        final PlanningPeriod record = (await h.reads.findByKey(
          h.profileId,
          lifeAreaId: h.lifeAreaId,
          kind: PlanningPeriodKind.month,
          periodKey: '2024-06',
        ))!;
        expect(record.planIntentionMd, 'v1');
        expect(record.reflectionMd, 'done');
        expect(record.revision, 2);
      },
    );

    test(
      '[TEST-DB-PLAN-RECORD-UNIQUE][MVP][TASK-5.4][R-PLAN-001] '
      'the same period key in a different area is a distinct record',
      () async {
        for (final String area in <String>['area-1', 'area-2']) {
          await h.service.savePlanningRecord(
            commandId: h.nextCommandId('day-$area'),
            profileId: h.profileId,
            input: SavePlanningRecordInput(
              lifeAreaId: area,
              kind: PlanningPeriodKind.day,
              periodKey: '2024-06-01',
              morningPlanMd: SectionEdit.set('area $area'),
            ),
          );
        }

        expect(
          await h.scalar(
            'SELECT COUNT(*) AS c FROM planning_periods '
            'WHERE profile_id = ? AND kind = ? AND period_key = ?',
            <Object?>[h.profileId.value, 'day', '2024-06-01'],
          ),
          2,
        );
      },
    );

    test('[TEST-DB-PLAN-RECORD-SECTION-GUARD][MVP][TASK-5.4][R-PLAN-001] '
        'setting a daily section on a weekly record is rejected', () async {
      final Result<CommittedCommandResult> result = await h.service
          .savePlanningRecord(
            commandId: h.nextCommandId('bad-1'),
            profileId: h.profileId,
            input: SavePlanningRecordInput(
              lifeAreaId: h.lifeAreaId.value,
              kind: PlanningPeriodKind.week,
              periodKey: '2024-W23',
              morningPlanMd: SectionEdit.set('not allowed on a week'),
            ),
          );

      expect(result.failureOrNull?.code, 'planner.invalid_section');
      expect(await h.scalar('SELECT COUNT(*) AS c FROM planning_periods'), 0);
    });

    test(
      '[TEST-DB-PLAN-RECORD-CROSS-AREA-FK][MVP][TASK-5.4][R-GEN-002] '
      'a record referencing a missing area is rejected by the composite FK',
      () async {
        await expectLater(
          h.db.customStatement(
            'INSERT INTO planning_periods '
            '(id, profile_id, life_area_id, kind, period_key, prompt_version, '
            'revision, created_at_utc, updated_at_utc) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'p-x',
              h.profileId.value,
              'ghost-area',
              'day',
              '2024-06-02',
              1,
              1,
              0,
              0,
            ],
          ),
          throwsA(isA<Object>()),
        );
      },
    );

    test('[TEST-DB-PLAN-RECORD-IDEMPOTENT][MVP][TASK-5.4][R-GEN-005] '
        'replaying the same save command returns the stored receipt', () async {
      final input = SavePlanningRecordInput(
        lifeAreaId: h.lifeAreaId.value,
        kind: PlanningPeriodKind.day,
        periodKey: '2024-06-03',
        morningPlanMd: SectionEdit.set('once'),
      );
      final Result<CommittedCommandResult> first = await h.service
          .savePlanningRecord(
            commandId: h.nextCommandId('idem-1'),
            profileId: h.profileId,
            input: input,
          );
      final Result<CommittedCommandResult> second = await h.service
          .savePlanningRecord(
            commandId: h.nextCommandId('idem-1'),
            profileId: h.profileId,
            input: input,
          );

      expect(first.failureOrNull, isNull);
      expect(second.valueOrNull?.replayed, isTrue);
      expect(await h.scalar('SELECT COUNT(*) AS c FROM planning_periods'), 1);
    });
  });
}
