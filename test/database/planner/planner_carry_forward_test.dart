import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planner_repository.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_entry_role.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';

import 'planner_test_support.dart';

/// Reference and carry-forward preview (R-PLAN-002, R-PLAN-003).
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

  Future<String> addRef(
    PlanningPeriod period,
    PlanningReferenceType type,
    String entityId,
    String seed,
  ) async {
    final Result<CommittedCommandResult> r = await h.service.addReference(
      commandId: h.nextCommandId(seed),
      profileId: h.profileId,
      input: AddReferenceInput(
        periodId: period.id.value,
        referenceType: type,
        entityId: entityId,
      ),
    );
    expect(r.failureOrNull, isNull);
    final List<PlanningEntry> entries = await h.reads.entriesOf(
      h.profileId,
      period.id,
    );
    return entries.firstWhere((PlanningEntry e) => e.entityId == entityId).id;
  }

  test(
    '[TEST-DB-PLAN-REF-ADD][MVP][TASK-5.4][R-PLAN-002] '
    'a planning record references tasks/goals/habits without cloning them',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-01');
      await addRef(day, PlanningReferenceType.task, 'task-a', 'a');
      await addRef(day, PlanningReferenceType.goal, 'goal-b', 'b');
      await addRef(day, PlanningReferenceType.habit, 'habit-c', 'c');
      await addRef(day, PlanningReferenceType.note, 'note-d', 'd');

      final List<PlanningEntry> entries = await h.reads.entriesOf(
        h.profileId,
        day.id,
      );
      expect(entries, hasLength(4));
      expect(
        entries.every((PlanningEntry e) => e.role == PlanningEntryRole.planned),
        isTrue,
      );
      // No task/goal/habit/note rows are created by referencing them.
      expect(await h.scalar('SELECT COUNT(*) AS c FROM tasks'), 0);
    },
  );

  test('[TEST-DB-PLAN-CARRY-PREVIEW][MVP][TASK-5.4][R-PLAN-003] '
      'carry-forward preview lists only incomplete references', () async {
    final PlanningPeriod day = await saveDay('2024-06-01');
    await addRef(day, PlanningReferenceType.task, 'task-done', 'done');
    await addRef(day, PlanningReferenceType.task, 'task-open-1', 'o1');
    await addRef(day, PlanningReferenceType.task, 'task-open-2', 'o2');

    final List<CarryForwardCandidate> preview = await h.reads
        .previewCarryForward(
          h.profileId,
          day.id,
          completeEntityIds: <String>{'task-done'},
        );

    expect(
      preview.map((CarryForwardCandidate c) => c.entry.entityId).toSet(),
      <String>{'task-open-1', 'task-open-2'},
    );
  });

  test(
    '[TEST-DB-PLAN-CARRY-APPLY][MVP][TASK-5.4][R-PLAN-003] '
    'applying carry-forward records the relation and never alters due dates',
    () async {
      // A real task row with a due date to prove carry-forward leaves it alone.
      await h.db.customStatement(
        'INSERT INTO tasks '
        '(id, profile_id, life_area_id, title, status, priority, due_date, '
        'rank, created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'task-open-1',
          h.profileId.value,
          h.lifeAreaId.value,
          'Carry me',
          'open',
          'none',
          '2024-06-01',
          'n',
          0,
          0,
        ],
      );

      final PlanningPeriod monday = await saveDay('2024-06-01');
      final PlanningPeriod tuesday = await saveDay('2024-06-02');
      final String sourceEntryId = await addRef(
        monday,
        PlanningReferenceType.task,
        'task-open-1',
        'src',
      );

      final Result<CommittedCommandResult> result = await h.service
          .applyCarryForward(
            commandId: h.nextCommandId('carry-1'),
            profileId: h.profileId,
            input: CarryForwardInput(
              sourcePeriodId: monday.id.value,
              targetPeriodId: tuesday.id.value,
              sourceEntryIds: <String>[sourceEntryId],
            ),
          );

      expect(result.failureOrNull, isNull);
      final List<PlanningEntry> tuesdayEntries = await h.reads.entriesOf(
        h.profileId,
        tuesday.id,
      );
      expect(tuesdayEntries, hasLength(1));
      final PlanningEntry carried = tuesdayEntries.single;
      expect(carried.role, PlanningEntryRole.carry);
      expect(carried.carriedFromEntryId, sourceEntryId);
      expect(carried.entityId, 'task-open-1');

      // The task's due date is untouched (R-PLAN-003).
      final Map<String, Object?>? task = await h.firstRow(
        'SELECT due_date FROM tasks WHERE id = ?',
        <Object?>['task-open-1'],
      );
      expect(task!['due_date'], '2024-06-01');
    },
  );

  test(
    '[TEST-DB-PLAN-CARRY-CHAIN][MVP][TASK-5.4][R-PLAN-003] '
    'the carried-from relation forms an auditable carry chain across periods',
    () async {
      final PlanningPeriod d1 = await saveDay('2024-06-01');
      final PlanningPeriod d2 = await saveDay('2024-06-02');
      final PlanningPeriod d3 = await saveDay('2024-06-03');
      final String e1 = await addRef(
        d1,
        PlanningReferenceType.task,
        'task-x',
        'x',
      );

      await h.service.applyCarryForward(
        commandId: h.nextCommandId('c1'),
        profileId: h.profileId,
        input: CarryForwardInput(
          sourcePeriodId: d1.id.value,
          targetPeriodId: d2.id.value,
          sourceEntryIds: <String>[e1],
        ),
      );
      final String e2 = (await h.reads.entriesOf(h.profileId, d2.id)).single.id;
      await h.service.applyCarryForward(
        commandId: h.nextCommandId('c2'),
        profileId: h.profileId,
        input: CarryForwardInput(
          sourcePeriodId: d2.id.value,
          targetPeriodId: d3.id.value,
          sourceEntryIds: <String>[e2],
        ),
      );

      final PlanningEntry e3 = (await h.reads.entriesOf(
        h.profileId,
        d3.id,
      )).single;
      expect(e3.carriedFromEntryId, e2);
      // Walk the chain back to the original planned entry.
      final PlanningEntry back2 = (await h.reads.entriesOf(
        h.profileId,
        d2.id,
      )).single;
      expect(back2.carriedFromEntryId, e1);
    },
  );

  test(
    '[TEST-DB-PLAN-CARRY-INHERIT-AREA][MVP][TASK-5.4][R-GEN-002] '
    'planning entries inherit their period area through the composite FK',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-01');
      // An entry that points at a non-existent period is rejected by the FK.
      await expectLater(
        h.db.customStatement(
          'INSERT INTO planning_entries '
          '(id, profile_id, period_id, entity_type, entity_id, role, rank, '
          'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'entry-x',
            h.profileId.value,
            'ghost-period',
            'task',
            'task-z',
            'planned',
            'n',
            0,
            0,
          ],
        ),
        throwsA(isA<Object>()),
      );
      // A valid entry against the real period succeeds.
      await addRef(day, PlanningReferenceType.task, 'task-z', 'z');
      expect(
        await h.scalar(
          'SELECT COUNT(*) AS c FROM planning_entries WHERE period_id = ?',
          <Object?>[day.id.value],
        ),
        1,
      );
    },
  );

  test('[TEST-DB-PLAN-CARRY-EMPTY][MVP][TASK-5.4][R-PLAN-003] '
      'carry-forward with no selected references is rejected', () async {
    final PlanningPeriod d1 = await saveDay('2024-06-01');
    final PlanningPeriod d2 = await saveDay('2024-06-02');
    final Result<CommittedCommandResult> result = await h.service
        .applyCarryForward(
          commandId: h.nextCommandId('empty'),
          profileId: h.profileId,
          input: CarryForwardInput(
            sourcePeriodId: d1.id.value,
            targetPeriodId: d2.id.value,
            sourceEntryIds: const <String>[],
          ),
        );
    expect(result.failureOrNull?.code, 'planner.carry_forward_empty');
  });
}
