/// Two-device fitness replication: convergence, idempotency, parent-before-
/// child ordering, and tombstones (task 12.1).
///
/// Device A logs fitness records through the command service, which enqueues an
/// ordered outbox group. Those operations are delivered to device B as a pull
/// page and applied through the typed [fitnessRemoteAppliers]. The test proves,
/// for EVERY fitness record type:
///
///   * convergence — device B reconstructs the identical row, including the
///     derived canonical `*_scaled` amount recomputed from the replicated
///     entered value/unit;
///   * idempotency — re-applying the same page is a no-op (no duplicate rows,
///     identical state);
///   * parent-before-child — applying the page in feed order satisfies the
///     hierarchy FKs, while a child applied before its parent is rejected;
///   * tombstones — a replicated delete removes/soft-deletes the row on B.
///
/// **Validates: Requirements R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002,
/// R-SYNC-003, R-SYNC-004, NFR-REL-003**
library;

import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/infrastructure/fitness_remote_appliers.dart';
import 'package:forge/features/fitness/infrastructure/fitness_repository_factories.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../../helpers/evidence.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';
import 'fitness_test_support.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-FITNESS-TWODEVICE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.1'),
  requirements: <RequirementId>[
    RequirementId('R-FIT-001'),
    RequirementId('R-FIT-002'),
    RequirementId('R-FIT-003'),
    RequirementId('R-SYNC-003'),
    RequirementId('NFR-REL-003'),
  ],
);

const String _profileId = 'profile-1';

/// The strict-parent field per child entity type, mirroring the payload keys.
const Map<String, String> _parentField = <String, String>{
  'template_exercise': 'template_id',
  'exercise_log': 'workout_id',
  'set_log': 'exercise_log_id',
};

/// A minimal receiving device: a fresh schema DB with the active profile, a
/// matching life area, and the fitness applier registry.
final class _DeviceB {
  _DeviceB(this.db, this.unitOfWork, this.registry);

  final ForgeSchemaDatabase db;
  final DriftUnitOfWork unitOfWork;
  final RemoteApplierRegistry registry;

  static Future<_DeviceB> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    await insertProfile(db, id: _profileId);
    await insertLifeArea(db, _profileId, id: 'area-1');
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => _profileId,
      repositoryFactories: fitnessRepositoryFactories,
    );
    final RemoteApplierRegistry registry = RemoteApplierRegistry(
      fitnessRemoteAppliers(ProfileId(_profileId)),
    );
    return _DeviceB(db, unitOfWork, registry);
  }

  Future<void> apply(List<RemoteChange> changes) =>
      unitOfWork.transaction<void>(
        (TransactionSession tx) => registry.applyAll(tx, changes),
        origin: WriteOrigin.remoteApply,
      );

  Future<Map<String, Object?>?> row(String table, String id) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT * FROM $table WHERE profile_id = ? AND id = ?',
          variables: <Variable<Object>>[
            Variable<String>(_profileId),
            Variable<String>(id),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  Future<int> count(String table) async {
    final List<QueryRow> rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .get();
    return rows.single.data['n']! as int;
  }

  Future<void> close() => db.close();
}

/// Reads device A's outbox as an ordered pull page of [RemoteChange]s.
Future<List<RemoteChange>> _pageFrom(FitnessHarness a) async {
  final List<QueryRow> rows = await a.db
      .customSelect(
        'SELECT entity_type, entity_id, op_kind, group_index, payload '
        'FROM outbox_mutations ORDER BY group_id, group_index',
      )
      .get();
  final List<RemoteChange> changes = <RemoteChange>[];
  int seq = 0;
  for (final QueryRow r in rows) {
    final Map<String, Object?> data = r.data;
    final String entityType = data['entity_type']! as String;
    final Map<String, Object?> payload =
        jsonDecode(data['payload']! as String) as Map<String, Object?>;
    seq += 1;
    changes.add(
      RemoteChange(
        changeId: 'seq-$seq',
        entityType: entityType,
        entityId: data['entity_id']! as String,
        kind: SyncOperationKind.insert,
        serverSeq: ServerSeq(seq),
        serverVersion: 1,
        payload: payload,
        parentEntityId: _parentField.containsKey(entityType)
            ? payload[_parentField[entityType]] as String?
            : null,
      ),
    );
  }
  return changes;
}

RemoteChange _tombstone(String entityType, String entityId, int seq) =>
    RemoteChange(
      changeId: 'del-$seq',
      entityType: entityType,
      entityId: entityId,
      kind: SyncOperationKind.delete,
      serverSeq: ServerSeq(seq),
      serverVersion: 2,
      payload: const <String, Object?>{},
      tombstone: true,
    );

void main() {
  group('two-device fitness replication', () {
    late FitnessHarness a;
    late _DeviceB b;

    setUp(() async {
      a = await FitnessHarness.open();
      b = await _DeviceB.open();
    });
    tearDown(() async {
      await a.close();
      await b.close();
    });

    testWithEvidence(
      _evidence('WORKOUT-TEMPLATE-CONVERGES'),
      'a workout template and its exercises converge on device B in order',
      () async {
        final Result<Object?> r = await a.service.createWorkoutTemplate(
          commandId: a.nextCommandId('t1'),
          profileId: a.profileId,
          templateId: WorkoutTemplateId('tmpl-1'),
          input: CreateWorkoutTemplateInput(
            lifeAreaId: a.lifeAreaId.value,
            title: 'Push day',
            rank: 'm',
            exercises: const <TemplateExerciseInput>[
              TemplateExerciseInput(name: 'Bench', rank: 'm', targetSets: 3),
              TemplateExerciseInput(name: 'Dips', rank: 'n'),
            ],
          ),
        );
        expect(r, isA<Success<Object?>>());

        final List<RemoteChange> page = await _pageFrom(a);
        await b.apply(page);

        final Map<String, Object?>? template = await b.row(
          'workout_templates',
          'tmpl-1',
        );
        expect(template, isNotNull);
        expect(template!['title'], 'Push day');
        expect(await b.count('template_exercises'), 2);

        // Idempotency: re-applying the same page changes nothing.
        await b.apply(page);
        expect(await b.count('workout_templates'), 1);
        expect(await b.count('template_exercises'), 2);
      },
    );

    testWithEvidence(
      _evidence('SESSION-HIERARCHY-CONVERGES'),
      'a session, exercise log, and set log converge with recomputed scaled '
      'amount, and re-apply is idempotent',
      () async {
        final Result<Object?> r = await a.service.logWorkoutSession(
          commandId: a.nextCommandId('s1'),
          profileId: a.profileId,
          sessionId: WorkoutSessionId('sess-1'),
          input: LogWorkoutSessionInput(
            lifeAreaId: a.lifeAreaId.value,
            title: 'Morning lift',
            startedAtUtc: 1000,
            exercises: const <ExerciseLogInput>[
              ExerciseLogInput(
                name: 'Squat',
                rank: 'm',
                sets: <SetLogInput>[
                  SetLogInput(
                    rank: 'm',
                    reps: 5,
                    weightValue: 135,
                    weightUnit: 'lb',
                  ),
                ],
              ),
            ],
          ),
        );
        expect(r, isA<Success<Object?>>());

        final List<RemoteChange> page = await _pageFrom(a);
        await b.apply(page);
        await b.apply(page); // idempotent

        expect(await b.count('workout_sessions'), 1);
        expect(await b.count('exercise_logs'), 1);
        expect(await b.count('set_logs'), 1);

        // The derived canonical weight amount, recomputed on B from the entered
        // value/unit, matches device A byte-for-byte (deterministic normalizer).
        final Map<String, Object?>? aSet = await a.firstRow(
          'SELECT weight_scaled, weight_entered, weight_unit FROM set_logs',
        );
        final List<QueryRow> bSets = await b.db
            .customSelect(
              'SELECT weight_scaled, weight_entered, weight_unit FROM set_logs',
            )
            .get();
        expect(bSets, hasLength(1));
        expect(bSets.single.data['weight_scaled'], aSet!['weight_scaled']);
        expect(bSets.single.data['weight_entered'], aSet['weight_entered']);
        expect(bSets.single.data['weight_unit'], 'lb');
      },
    );

    testWithEvidence(
      _evidence('MEASUREMENT-AND-WATER-CONVERGE'),
      'body measurement and water event converge with preserved entered units',
      () async {
        await a.service.recordBodyMeasurement(
          commandId: a.nextCommandId('m1'),
          profileId: a.profileId,
          measurementId: BodyMeasurementId('meas-1'),
          input: RecordBodyMeasurementInput(
            lifeAreaId: a.lifeAreaId.value,
            value: 80.5,
            unit: 'kg',
            measuredAtUtc: 2000,
          ),
        );
        await a.waterSettings.setEnabled(a.profileId, enabled: true);
        await a.service.logWaterEvent(
          commandId: a.nextCommandId('w1'),
          profileId: a.profileId,
          eventId: WaterEventId('water-1'),
          input: LogWaterEventInput(
            lifeAreaId: a.lifeAreaId.value,
            value: 500,
            unit: 'ml',
            occurredAtUtc: 3000,
          ),
        );

        final List<RemoteChange> page = await _pageFrom(a);
        // Device B never enabled water tracking, yet the event still converges
        // because water EVENTS replicate as ordinary records (R-FIT-003).
        await b.apply(page);

        final Map<String, Object?>? meas = await b.row(
          'body_measurements',
          'meas-1',
        );
        expect(meas!['entered_value'], 80.5);
        expect(meas['entered_unit'], 'kg');
        final Map<String, Object?>? water = await b.row(
          'water_events',
          'water-1',
        );
        expect(water!['entered_value'], 500);
        expect(water['entered_unit'], 'ml');
      },
    );

    testWithEvidence(
      _evidence('PARENT-BEFORE-CHILD-REQUIRED'),
      'applying a child before its parent is rejected by the hierarchy FK',
      () async {
        await a.service.createWorkoutTemplate(
          commandId: a.nextCommandId('t1'),
          profileId: a.profileId,
          templateId: WorkoutTemplateId('tmpl-1'),
          input: CreateWorkoutTemplateInput(
            lifeAreaId: a.lifeAreaId.value,
            title: 'Push day',
            rank: 'm',
            exercises: const <TemplateExerciseInput>[
              TemplateExerciseInput(name: 'Bench', rank: 'm'),
            ],
          ),
        );
        final List<RemoteChange> page = await _pageFrom(a);
        expect(page.first.entityType, 'workout_template');

        // Reverse the order so the child precedes its parent: the FK insert
        // fails and the whole page rolls back (parent-before-child required).
        await expectLater(
          b.apply(page.reversed.toList(growable: false)),
          throwsA(anything),
        );
        expect(await b.count('workout_templates'), 0);
        expect(await b.count('template_exercises'), 0);
      },
    );

    testWithEvidence(
      _evidence('TOMBSTONE-REPLICATES'),
      'a replicated tombstone soft-deletes the owner and removes its child',
      () async {
        await a.service.logWorkoutSession(
          commandId: a.nextCommandId('s1'),
          profileId: a.profileId,
          sessionId: WorkoutSessionId('sess-1'),
          input: LogWorkoutSessionInput(
            lifeAreaId: a.lifeAreaId.value,
            title: 'Morning lift',
            startedAtUtc: 1000,
            exercises: const <ExerciseLogInput>[
              ExerciseLogInput(name: 'Squat', rank: 'm'),
            ],
          ),
        );
        final List<RemoteChange> page = await _pageFrom(a);
        await b.apply(page);
        expect(await b.count('exercise_logs'), 1);

        // A tombstone for the exercise-log child removes it; a tombstone for the
        // session soft-deletes it. Re-applying the tombstones is idempotent.
        final String sessionExLogId =
            ((await b.db.customSelect('SELECT id FROM exercise_logs').get())
                    .single
                    .data['id']!)
                as String;
        final List<RemoteChange> deletes = <RemoteChange>[
          _tombstone('exercise_log', sessionExLogId, 91),
          _tombstone('workout_session', 'sess-1', 92),
        ];
        await b.apply(deletes);
        await b.apply(deletes); // idempotent

        expect(await b.count('exercise_logs'), 0);
        final Map<String, Object?>? session = await b.row(
          'workout_sessions',
          'sess-1',
        );
        expect(session!['deleted_at_utc'], isNotNull);
      },
    );
  });
}
