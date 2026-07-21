import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/infrastructure/fitness_mapper.dart';

/// Read-side projections for fitness history (R-FIT-001, R-FIT-002, R-FIT-004).
///
/// The read repository reads the active local generation directly (it is not
/// transaction-scoped). It returns immutable domain aggregates so callers see
/// the exact entered values behind any chart, honoring the non-medical,
/// records-exposed presentation policy (R-FIT-004).
final class FitnessReadRepository {
  FitnessReadRepository(this.db);

  final ForgeSchemaDatabase db;

  /// Active (non-deleted) workout templates for [profileId], rank-ordered.
  Future<List<WorkoutTemplate>> templates(String profileId) async {
    final List<WorkoutTemplateRow> rows =
        await (db.select(db.workoutTemplates)
              ..where(
                (WorkoutTemplates t) =>
                    t.profileId.equals(profileId) & t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<WorkoutTemplates>>[
                (WorkoutTemplates t) => OrderingTerm.asc(t.rank),
                (WorkoutTemplates t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return rows.map(FitnessMapper.templateFromRow).toList(growable: false);
  }

  /// Workout-session history for [profileId] within the inclusive UTC-micros
  /// window `[fromUtc, toUtc]`, newest first.
  Future<List<WorkoutSession>> sessionHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async {
    final List<WorkoutSessionRow> rows =
        await (db.select(db.workoutSessions)
              ..where(
                (WorkoutSessions s) =>
                    s.profileId.equals(profileId) &
                    s.deletedAtUtc.isNull() &
                    s.startedAtUtc.isBiggerOrEqualValue(fromUtc) &
                    s.startedAtUtc.isSmallerOrEqualValue(toUtc),
              )
              ..orderBy(<OrderClauseGenerator<WorkoutSessions>>[
                (WorkoutSessions s) => OrderingTerm.desc(s.startedAtUtc),
                (WorkoutSessions s) => OrderingTerm.asc(s.id),
              ]))
            .get();
    return rows.map(FitnessMapper.sessionFromRow).toList(growable: false);
  }

  /// The single active (non-deleted) workout session [sessionId] for
  /// [profileId], or null when absent. Exposes the underlying record behind a
  /// `/fitness/<id>` deep link (R-FIT-001, R-FIT-004).
  Future<WorkoutSession?> findSession(
    String profileId,
    String sessionId,
  ) async {
    final WorkoutSessionRow? row =
        await (db.select(db.workoutSessions)..where(
              (WorkoutSessions s) =>
                  s.profileId.equals(profileId) &
                  s.id.equals(sessionId) &
                  s.deletedAtUtc.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : FitnessMapper.sessionFromRow(row);
  }

  /// The exercises performed in [sessionId], rank-ordered. Exposes the
  /// underlying records behind any session summary (R-FIT-004).
  Future<List<ExerciseLog>> exerciseLogs(
    String profileId,
    String sessionId,
  ) async {
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

  /// The sets performed in [exerciseLogId], rank-ordered. Each set preserves
  /// its entered weight/distance unit (R-FIT-002, R-FIT-004).
  Future<List<SetLog>> setLogs(String profileId, String exerciseLogId) async {
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

  /// Body-weight measurement history for [profileId] within the inclusive
  /// UTC-micros window `[fromUtc, toUtc]`, newest first. Each measurement
  /// preserves its entered value/unit (R-FIT-002).
  Future<List<BodyMeasurement>> measurementHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
    BodyMeasurementKind kind = BodyMeasurementKind.weight,
  }) async {
    final List<BodyMeasurementRow> rows =
        await (db.select(db.bodyMeasurements)
              ..where(
                (BodyMeasurements m) =>
                    m.profileId.equals(profileId) &
                    m.deletedAtUtc.isNull() &
                    m.kind.equals(kind.wire) &
                    m.measuredAtUtc.isBiggerOrEqualValue(fromUtc) &
                    m.measuredAtUtc.isSmallerOrEqualValue(toUtc),
              )
              ..orderBy(<OrderClauseGenerator<BodyMeasurements>>[
                (BodyMeasurements m) => OrderingTerm.desc(m.measuredAtUtc),
                (BodyMeasurements m) => OrderingTerm.asc(m.id),
              ]))
            .get();
    return rows.map(FitnessMapper.measurementFromRow).toList(growable: false);
  }

  /// Optional water-event history for [profileId] within the inclusive
  /// UTC-micros window `[fromUtc, toUtc]`, newest first. Each event preserves
  /// its entered value/unit (R-FIT-003). History is returned regardless of the
  /// current water-tracking preference so re-enabling never loses records.
  Future<List<WaterEvent>> waterEventHistory(
    String profileId, {
    required int fromUtc,
    required int toUtc,
  }) async {
    final List<WaterEventRow> rows =
        await (db.select(db.waterEvents)
              ..where(
                (WaterEvents w) =>
                    w.profileId.equals(profileId) &
                    w.deletedAtUtc.isNull() &
                    w.occurredAtUtc.isBiggerOrEqualValue(fromUtc) &
                    w.occurredAtUtc.isSmallerOrEqualValue(toUtc),
              )
              ..orderBy(<OrderClauseGenerator<WaterEvents>>[
                (WaterEvents w) => OrderingTerm.desc(w.occurredAtUtc),
                (WaterEvents w) => OrderingTerm.asc(w.id),
              ]))
            .get();
    return rows.map(FitnessMapper.waterEventFromRow).toList(growable: false);
  }
}
