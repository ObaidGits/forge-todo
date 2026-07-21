import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/infrastructure/fitness_mapper.dart';

/// Transaction-scoped write access to the fitness tables (R-FIT-001, R-FIT-002).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). Workout templates,
/// sessions, and body-weight measurements are direct-area owners; their
/// exercises, sets, and template exercises are inserted as inherited-area
/// children in the same semantic transaction.
final class FitnessWriteRepository {
  FitnessWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- workout templates --------------------------------------------------

  Future<void> insertTemplate(
    WorkoutTemplate template, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.workoutTemplates)
        .insert(FitnessMapper.templateToInsert(template, profileId: profileId));
  }

  Future<WorkoutTemplate?> findTemplate(
    String profileId,
    String templateId,
  ) async {
    scope.ensureActive();
    final WorkoutTemplateRow? row =
        await (db.select(db.workoutTemplates)..where(
              (WorkoutTemplates t) =>
                  t.profileId.equals(profileId) & t.id.equals(templateId),
            ))
            .getSingleOrNull();
    return row == null ? null : FitnessMapper.templateFromRow(row);
  }

  Future<void> updateTemplate(
    WorkoutTemplate template, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await (db.update(db.workoutTemplates)..where(
          (WorkoutTemplates t) =>
              t.profileId.equals(profileId) & t.id.equals(template.id.value),
        ))
        .write(
          WorkoutTemplatesCompanion(
            title: Value<String>(template.title),
            rank: Value<String>(template.rank),
            status: Value<String>(template.status.wire),
            noteId: Value<String?>(template.noteId),
            revision: Value<int>(template.revision),
            updatedAtUtc: Value<int>(template.updatedAtUtc),
            deletedAtUtc: Value<int?>(template.deletedAtUtc),
          ),
        );
  }

  Future<void> insertTemplateExercise(
    TemplateExercise exercise, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.templateExercises)
        .insert(
          FitnessMapper.templateExerciseToInsert(
            exercise,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<List<TemplateExercise>> templateExercises(
    String profileId,
    String templateId,
  ) async {
    scope.ensureActive();
    final List<TemplateExerciseRow> rows =
        await (db.select(db.templateExercises)
              ..where(
                (TemplateExercises e) =>
                    e.profileId.equals(profileId) &
                    e.templateId.equals(templateId),
              )
              ..orderBy(<OrderClauseGenerator<TemplateExercises>>[
                (TemplateExercises e) => OrderingTerm.asc(e.rank),
                (TemplateExercises e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows
        .map(FitnessMapper.templateExerciseFromRow)
        .toList(growable: false);
  }

  // ---- workout sessions ---------------------------------------------------

  Future<void> insertSession(
    WorkoutSession session, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.workoutSessions)
        .insert(FitnessMapper.sessionToInsert(session, profileId: profileId));
  }

  Future<WorkoutSession?> findSession(
    String profileId,
    String sessionId,
  ) async {
    scope.ensureActive();
    final WorkoutSessionRow? row =
        await (db.select(db.workoutSessions)..where(
              (WorkoutSessions s) =>
                  s.profileId.equals(profileId) & s.id.equals(sessionId),
            ))
            .getSingleOrNull();
    return row == null ? null : FitnessMapper.sessionFromRow(row);
  }

  /// Every current (non-tombstoned) workout-session id for [profileId], used by
  /// the unified-search source rebuild path to regenerate `search_documents`
  /// entirely from authoritative rows (R-SEARCH-001). Soft-deleted sessions are
  /// excluded so their documents are removed/hidden.
  Future<List<String>> activeSessionIds(String profileId) async {
    scope.ensureActive();
    final List<WorkoutSessionRow> rows =
        await (db.select(db.workoutSessions)
              ..where(
                (WorkoutSessions s) =>
                    s.profileId.equals(profileId) & s.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<WorkoutSessions>>[
                (WorkoutSessions s) => OrderingTerm.asc(s.id),
              ]))
            .get();
    return rows.map((WorkoutSessionRow r) => r.id).toList(growable: false);
  }

  Future<void> updateSession(
    WorkoutSession session, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await (db.update(db.workoutSessions)..where(
          (WorkoutSessions s) =>
              s.profileId.equals(profileId) & s.id.equals(session.id.value),
        ))
        .write(
          WorkoutSessionsCompanion(
            title: Value<String>(session.title),
            endedAtUtc: Value<int?>(session.endedAtUtc),
            durationSec: Value<int?>(session.durationSec),
            noteId: Value<String?>(session.noteId),
            revision: Value<int>(session.revision),
            updatedAtUtc: Value<int>(session.updatedAtUtc),
            deletedAtUtc: Value<int?>(session.deletedAtUtc),
          ),
        );
  }

  Future<void> insertExerciseLog(
    ExerciseLog log, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.exerciseLogs)
        .insert(
          FitnessMapper.exerciseLogToInsert(
            log,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<List<ExerciseLog>> exerciseLogs(
    String profileId,
    String sessionId,
  ) async {
    scope.ensureActive();
    final List<ExerciseLogRow> rows =
        await (db.select(db.exerciseLogs)
              ..where(
                (ExerciseLogs e) =>
                    e.profileId.equals(profileId) &
                    e.workoutId.equals(sessionId),
              )
              ..orderBy(<OrderClauseGenerator<ExerciseLogs>>[
                (ExerciseLogs e) => OrderingTerm.asc(e.rank),
                (ExerciseLogs e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows.map(FitnessMapper.exerciseLogFromRow).toList(growable: false);
  }

  Future<void> insertSetLog(
    SetLog set, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.setLogs)
        .insert(
          FitnessMapper.setLogToInsert(
            set,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<List<SetLog>> setLogs(String profileId, String exerciseLogId) async {
    scope.ensureActive();
    final List<SetLogRow> rows =
        await (db.select(db.setLogs)
              ..where(
                (SetLogs s) =>
                    s.profileId.equals(profileId) &
                    s.exerciseLogId.equals(exerciseLogId),
              )
              ..orderBy(<OrderClauseGenerator<SetLogs>>[
                (SetLogs s) => OrderingTerm.asc(s.rank),
                (SetLogs s) => OrderingTerm.asc(s.id),
              ]))
            .get();
    return rows.map(FitnessMapper.setLogFromRow).toList(growable: false);
  }

  // ---- body measurements --------------------------------------------------

  Future<void> insertMeasurement(
    BodyMeasurement measurement, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.bodyMeasurements)
        .insert(
          FitnessMapper.measurementToInsert(measurement, profileId: profileId),
        );
  }

  Future<BodyMeasurement?> findMeasurement(
    String profileId,
    String measurementId,
  ) async {
    scope.ensureActive();
    final BodyMeasurementRow? row =
        await (db.select(db.bodyMeasurements)..where(
              (BodyMeasurements m) =>
                  m.profileId.equals(profileId) & m.id.equals(measurementId),
            ))
            .getSingleOrNull();
    return row == null ? null : FitnessMapper.measurementFromRow(row);
  }

  Future<void> updateMeasurement(
    BodyMeasurement measurement, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await (db.update(db.bodyMeasurements)..where(
          (BodyMeasurements m) =>
              m.profileId.equals(profileId) & m.id.equals(measurement.id.value),
        ))
        .write(
          BodyMeasurementsCompanion(
            valueScaled: Value<int>(measurement.value.canonicalValue),
            enteredValue: Value<double>(
              measurement.value.enteredValue.toDouble(),
            ),
            enteredUnit: Value<String>(measurement.value.enteredUnit),
            measuredAtUtc: Value<int>(measurement.measuredAtUtc),
            note: Value<String?>(measurement.note),
            revision: Value<int>(measurement.revision),
            updatedAtUtc: Value<int>(measurement.updatedAtUtc),
            deletedAtUtc: Value<int?>(measurement.deletedAtUtc),
          ),
        );
  }

  // ---- water events -------------------------------------------------------

  Future<void> insertWaterEvent(
    WaterEvent event, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.waterEvents)
        .insert(FitnessMapper.waterEventToInsert(event, profileId: profileId));
  }

  Future<WaterEvent?> findWaterEvent(String profileId, String eventId) async {
    scope.ensureActive();
    final WaterEventRow? row =
        await (db.select(db.waterEvents)..where(
              (WaterEvents w) =>
                  w.profileId.equals(profileId) & w.id.equals(eventId),
            ))
            .getSingleOrNull();
    return row == null ? null : FitnessMapper.waterEventFromRow(row);
  }

  Future<void> updateWaterEvent(
    WaterEvent event, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await (db.update(db.waterEvents)..where(
          (WaterEvents w) =>
              w.profileId.equals(profileId) & w.id.equals(event.id.value),
        ))
        .write(
          WaterEventsCompanion(
            amountScaled: Value<int>(event.amount.canonicalValue),
            enteredValue: Value<double>(event.amount.enteredValue.toDouble()),
            enteredUnit: Value<String>(event.amount.enteredUnit),
            occurredAtUtc: Value<int>(event.occurredAtUtc),
            note: Value<String?>(event.note),
            revision: Value<int>(event.revision),
            updatedAtUtc: Value<int>(event.updatedAtUtc),
            deletedAtUtc: Value<int?>(event.deletedAtUtc),
          ),
        );
  }

  // ---- idempotent remote-apply upserts / tombstones (task 12.1) -----------
  //
  // The typed remote appliers apply a pulled change by upserting the row on its
  // primary key and marking a tombstone. `insertOnConflictUpdate` keyed on the
  // `id` primary key makes re-applying the same change a no-op mutation, so the
  // appliers are idempotent (R-SYNC-002/R-SYNC-003, NFR-REL-003).

  Future<void> upsertTemplate(
    WorkoutTemplate template, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.workoutTemplates)
        .insertOnConflictUpdate(
          FitnessMapper.templateToInsert(template, profileId: profileId),
        );
  }

  Future<void> upsertTemplateExercise(
    TemplateExercise exercise, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.templateExercises)
        .insertOnConflictUpdate(
          FitnessMapper.templateExerciseToInsert(
            exercise,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<void> upsertSession(
    WorkoutSession session, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.workoutSessions)
        .insertOnConflictUpdate(
          FitnessMapper.sessionToInsert(session, profileId: profileId),
        );
  }

  Future<void> upsertExerciseLog(
    ExerciseLog log, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.exerciseLogs)
        .insertOnConflictUpdate(
          FitnessMapper.exerciseLogToInsert(
            log,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<void> upsertSetLog(
    SetLog set, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.setLogs)
        .insertOnConflictUpdate(
          FitnessMapper.setLogToInsert(
            set,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<void> upsertMeasurement(
    BodyMeasurement measurement, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.bodyMeasurements)
        .insertOnConflictUpdate(
          FitnessMapper.measurementToInsert(measurement, profileId: profileId),
        );
  }

  Future<void> upsertWaterEvent(
    WaterEvent event, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.waterEvents)
        .insertOnConflictUpdate(
          FitnessMapper.waterEventToInsert(event, profileId: profileId),
        );
  }

  /// Applies a remote tombstone to a top-level fitness owner by marking it
  /// soft-deleted. Idempotent: re-applying leaves the row deleted. A missing
  /// row is a no-op (the ordered feed applies the insert before the delete).
  Future<void> tombstoneTemplate(
    String id, {
    required String profileId,
    required int deletedAtUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.workoutTemplates)..where(
          (WorkoutTemplates t) =>
              t.profileId.equals(profileId) & t.id.equals(id),
        ))
        .write(
          WorkoutTemplatesCompanion(deletedAtUtc: Value<int?>(deletedAtUtc)),
        );
  }

  Future<void> tombstoneSession(
    String id, {
    required String profileId,
    required int deletedAtUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.workoutSessions)..where(
          (WorkoutSessions s) =>
              s.profileId.equals(profileId) & s.id.equals(id),
        ))
        .write(
          WorkoutSessionsCompanion(deletedAtUtc: Value<int?>(deletedAtUtc)),
        );
  }

  Future<void> tombstoneMeasurement(
    String id, {
    required String profileId,
    required int deletedAtUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.bodyMeasurements)..where(
          (BodyMeasurements m) =>
              m.profileId.equals(profileId) & m.id.equals(id),
        ))
        .write(
          BodyMeasurementsCompanion(deletedAtUtc: Value<int?>(deletedAtUtc)),
        );
  }

  Future<void> tombstoneWaterEvent(
    String id, {
    required String profileId,
    required int deletedAtUtc,
  }) async {
    scope.ensureActive();
    await (db.update(db.waterEvents)..where(
          (WaterEvents w) => w.profileId.equals(profileId) & w.id.equals(id),
        ))
        .write(WaterEventsCompanion(deletedAtUtc: Value<int?>(deletedAtUtc)));
  }

  /// Applies a remote tombstone to an inherited-area fitness child (template
  /// exercise, exercise log, set log) by removing the row. These children have
  /// no soft-delete column; they are removed with their parent. Idempotent.
  Future<void> deleteTemplateExercise(
    String id, {
    required String profileId,
  }) async {
    scope.ensureActive();
    await (db.delete(db.templateExercises)..where(
          (TemplateExercises e) =>
              e.profileId.equals(profileId) & e.id.equals(id),
        ))
        .go();
  }

  Future<void> deleteExerciseLog(String id, {required String profileId}) async {
    scope.ensureActive();
    await (db.delete(db.exerciseLogs)..where(
          (ExerciseLogs e) => e.profileId.equals(profileId) & e.id.equals(id),
        ))
        .go();
  }

  Future<void> deleteSetLog(String id, {required String profileId}) async {
    scope.ensureActive();
    await (db.delete(db.setLogs)..where(
          (SetLogs s) => s.profileId.equals(profileId) & s.id.equals(id),
        ))
        .go();
  }
}
