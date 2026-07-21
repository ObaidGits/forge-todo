import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';

/// Symmetric wire-payload codec for replicated fitness records (task 12.1;
/// R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002).
///
/// One place owns the replicated field set for every fitness entity so the
/// local outbox projector (which encodes a domain row into an outbox operation
/// payload) and the typed remote applier (which decodes a pulled change back
/// into a domain row) can never drift apart. The encoded map contains ONLY the
/// manifest-replicated fields: the entered value/unit are authoritative and
/// preserved verbatim, while the derived canonical `*_scaled` amount is
/// deliberately absent — the applier recomputes it deterministically from the
/// entered value/unit (data-model.md §3 "Local-only fields"). The local
/// soft-delete marker is absent too; a delete is a tombstone operation.
abstract final class FitnessReplicationPayload {
  // ---- workout template ----------------------------------------------------

  static Map<String, Object?> template(WorkoutTemplate template) =>
      <String, Object?>{
        'id': template.id.value,
        'life_area_id': template.lifeAreaId.value,
        'title': template.title,
        'rank': template.rank,
        'status': template.status.wire,
        'note_id': template.noteId,
        'revision': template.revision,
        'created_at_utc': template.createdAtUtc,
        'updated_at_utc': template.updatedAtUtc,
      };

  static WorkoutTemplate templateFrom(Map<String, Object?> p) =>
      WorkoutTemplate(
        id: WorkoutTemplateId(p['id']! as String),
        lifeAreaId: LifeAreaId(p['life_area_id']! as String),
        title: p['title']! as String,
        rank: p['rank']! as String,
        status: WorkoutTemplateStatus.fromWire(p['status']! as String),
        noteId: p['note_id'] as String?,
        revision: (p['revision']! as num).toInt(),
        createdAtUtc: (p['created_at_utc']! as num).toInt(),
        updatedAtUtc: (p['updated_at_utc']! as num).toInt(),
      );

  // ---- template exercise (child of template) ------------------------------

  static Map<String, Object?> templateExercise(TemplateExercise exercise) =>
      <String, Object?>{
        'id': exercise.id.value,
        'template_id': exercise.templateId.value,
        'name': exercise.name,
        'rank': exercise.rank,
        'target_sets': exercise.targetSets,
        'target_reps': exercise.targetReps,
        'notes': exercise.notes,
      };

  static TemplateExercise templateExerciseFrom(Map<String, Object?> p) =>
      TemplateExercise(
        id: TemplateExerciseId(p['id']! as String),
        templateId: WorkoutTemplateId(p['template_id']! as String),
        name: p['name']! as String,
        rank: p['rank']! as String,
        targetSets: (p['target_sets'] as num?)?.toInt(),
        targetReps: (p['target_reps'] as num?)?.toInt(),
        notes: p['notes'] as String?,
      );

  // ---- workout session ----------------------------------------------------

  static Map<String, Object?> session(WorkoutSession session) =>
      <String, Object?>{
        'id': session.id.value,
        'life_area_id': session.lifeAreaId.value,
        'template_id': session.templateId?.value,
        'title': session.title,
        'started_at_utc': session.startedAtUtc,
        'ended_at_utc': session.endedAtUtc,
        'duration_sec': session.durationSec,
        'note_id': session.noteId,
        'revision': session.revision,
        'created_at_utc': session.createdAtUtc,
        'updated_at_utc': session.updatedAtUtc,
      };

  static WorkoutSession sessionFrom(Map<String, Object?> p) => WorkoutSession(
    id: WorkoutSessionId(p['id']! as String),
    lifeAreaId: LifeAreaId(p['life_area_id']! as String),
    title: p['title']! as String,
    templateId: p['template_id'] == null
        ? null
        : WorkoutTemplateId(p['template_id']! as String),
    startedAtUtc: (p['started_at_utc']! as num).toInt(),
    endedAtUtc: (p['ended_at_utc'] as num?)?.toInt(),
    durationSec: (p['duration_sec'] as num?)?.toInt(),
    noteId: p['note_id'] as String?,
    revision: (p['revision']! as num).toInt(),
    createdAtUtc: (p['created_at_utc']! as num).toInt(),
    updatedAtUtc: (p['updated_at_utc']! as num).toInt(),
  );

  // ---- exercise log (child of session) ------------------------------------

  static Map<String, Object?> exerciseLog(ExerciseLog log) => <String, Object?>{
    'id': log.id.value,
    'workout_id': log.workoutId.value,
    'name': log.name,
    'rank': log.rank,
    'notes': log.notes,
  };

  static ExerciseLog exerciseLogFrom(Map<String, Object?> p) => ExerciseLog(
    id: ExerciseLogId(p['id']! as String),
    workoutId: WorkoutSessionId(p['workout_id']! as String),
    name: p['name']! as String,
    rank: p['rank']! as String,
    notes: p['notes'] as String?,
  );

  // ---- set log (child of exercise log) ------------------------------------

  static Map<String, Object?> setLog(SetLog set) => <String, Object?>{
    'id': set.id.value,
    'exercise_log_id': set.exerciseLogId.value,
    'rank': set.rank,
    'reps': set.reps,
    // Entered value/unit are authoritative; the canonical scaled amount is a
    // derived local-only column recomputed by the applier.
    'weight_entered': set.weight?.enteredValue,
    'weight_unit': set.weight?.enteredUnit,
    'duration_sec': set.durationSec,
    'distance_entered': set.distance?.enteredValue,
    'distance_unit': set.distance?.enteredUnit,
    'completed_at_utc': set.completedAtUtc,
  };

  static SetLog setLogFrom(Map<String, Object?> p) => SetLog(
    id: SetLogId(p['id']! as String),
    exerciseLogId: ExerciseLogId(p['exercise_log_id']! as String),
    rank: p['rank']! as String,
    reps: (p['reps'] as num?)?.toInt(),
    weight: _measure(p['weight_entered'] as num?, p['weight_unit'] as String?),
    durationSec: (p['duration_sec'] as num?)?.toInt(),
    distance: _measure(
      p['distance_entered'] as num?,
      p['distance_unit'] as String?,
    ),
    completedAtUtc: (p['completed_at_utc'] as num?)?.toInt(),
  );

  // ---- body measurement ---------------------------------------------------

  static Map<String, Object?> measurement(BodyMeasurement measurement) =>
      <String, Object?>{
        'id': measurement.id.value,
        'life_area_id': measurement.lifeAreaId.value,
        'kind': measurement.kind.wire,
        'entered_value': measurement.value.enteredValue,
        'entered_unit': measurement.value.enteredUnit,
        'measured_at_utc': measurement.measuredAtUtc,
        'note': measurement.note,
        'revision': measurement.revision,
        'created_at_utc': measurement.createdAtUtc,
        'updated_at_utc': measurement.updatedAtUtc,
      };

  static BodyMeasurement measurementFrom(Map<String, Object?> p) =>
      BodyMeasurement(
        id: BodyMeasurementId(p['id']! as String),
        lifeAreaId: LifeAreaId(p['life_area_id']! as String),
        kind: BodyMeasurementKind.fromWire(p['kind']! as String),
        value: MeasuredQuantity.of(
          p['entered_value']! as num,
          p['entered_unit']! as String,
        ),
        measuredAtUtc: (p['measured_at_utc']! as num).toInt(),
        note: p['note'] as String?,
        revision: (p['revision']! as num).toInt(),
        createdAtUtc: (p['created_at_utc']! as num).toInt(),
        updatedAtUtc: (p['updated_at_utc']! as num).toInt(),
      );

  // ---- water event --------------------------------------------------------

  static Map<String, Object?> waterEvent(WaterEvent event) => <String, Object?>{
    'id': event.id.value,
    'life_area_id': event.lifeAreaId.value,
    'entered_value': event.amount.enteredValue,
    'entered_unit': event.amount.enteredUnit,
    'occurred_at_utc': event.occurredAtUtc,
    'note': event.note,
    'revision': event.revision,
    'created_at_utc': event.createdAtUtc,
    'updated_at_utc': event.updatedAtUtc,
  };

  static WaterEvent waterEventFrom(Map<String, Object?> p) => WaterEvent(
    id: WaterEventId(p['id']! as String),
    lifeAreaId: LifeAreaId(p['life_area_id']! as String),
    amount: MeasuredQuantity.of(
      p['entered_value']! as num,
      p['entered_unit']! as String,
    ),
    occurredAtUtc: (p['occurred_at_utc']! as num).toInt(),
    note: p['note'] as String?,
    revision: (p['revision']! as num).toInt(),
    createdAtUtc: (p['created_at_utc']! as num).toInt(),
    updatedAtUtc: (p['updated_at_utc']! as num).toInt(),
  );

  static MeasuredQuantity? _measure(num? enteredValue, String? unit) {
    if (enteredValue == null || unit == null) {
      return null;
    }
    return MeasuredQuantity.of(enteredValue, unit);
  }
}
