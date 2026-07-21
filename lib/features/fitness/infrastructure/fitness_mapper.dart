import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';
import 'package:forge/features/fitness/domain/water_event.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';

/// Explicit mapping between fitness Drift rows and immutable domain aggregates
/// (design.md "Data Models").
///
/// Weight/distance/body-weight measurements are reconstructed from their stored
/// entered value/unit and canonical amount so the exact entered value survives
/// a round trip (R-FIT-002).
abstract final class FitnessMapper {
  // ---- workout templates --------------------------------------------------

  static WorkoutTemplate templateFromRow(WorkoutTemplateRow row) =>
      WorkoutTemplate(
        id: WorkoutTemplateId(row.id),
        lifeAreaId: LifeAreaId(row.lifeAreaId),
        title: row.title,
        rank: row.rank,
        status: WorkoutTemplateStatus.fromWire(row.status),
        noteId: row.noteId,
        revision: row.revision,
        createdAtUtc: row.createdAtUtc,
        updatedAtUtc: row.updatedAtUtc,
        deletedAtUtc: row.deletedAtUtc,
      );

  static WorkoutTemplatesCompanion templateToInsert(
    WorkoutTemplate template, {
    required String profileId,
  }) => WorkoutTemplatesCompanion.insert(
    id: template.id.value,
    profileId: profileId,
    lifeAreaId: template.lifeAreaId.value,
    title: template.title,
    rank: template.rank,
    status: template.status.wire,
    noteId: Value<String?>(template.noteId),
    revision: Value<int>(template.revision),
    createdAtUtc: template.createdAtUtc,
    updatedAtUtc: template.updatedAtUtc,
    deletedAtUtc: Value<int?>(template.deletedAtUtc),
  );

  static TemplateExercise templateExerciseFromRow(TemplateExerciseRow row) =>
      TemplateExercise(
        id: TemplateExerciseId(row.id),
        templateId: WorkoutTemplateId(row.templateId),
        name: row.name,
        rank: row.rank,
        targetSets: row.targetSets,
        targetReps: row.targetReps,
        notes: row.notes,
      );

  static TemplateExercisesCompanion templateExerciseToInsert(
    TemplateExercise exercise, {
    required String profileId,
    required int nowUtc,
  }) => TemplateExercisesCompanion.insert(
    id: exercise.id.value,
    profileId: profileId,
    templateId: exercise.templateId.value,
    name: exercise.name,
    rank: exercise.rank,
    targetSets: Value<int?>(exercise.targetSets),
    targetReps: Value<int?>(exercise.targetReps),
    notes: Value<String?>(exercise.notes),
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );

  // ---- workout sessions ---------------------------------------------------

  static WorkoutSession sessionFromRow(WorkoutSessionRow row) => WorkoutSession(
    id: WorkoutSessionId(row.id),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    title: row.title,
    templateId: row.templateId == null
        ? null
        : WorkoutTemplateId(row.templateId!),
    startedAtUtc: row.startedAtUtc,
    endedAtUtc: row.endedAtUtc,
    durationSec: row.durationSec,
    noteId: row.noteId,
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static WorkoutSessionsCompanion sessionToInsert(
    WorkoutSession session, {
    required String profileId,
  }) => WorkoutSessionsCompanion.insert(
    id: session.id.value,
    profileId: profileId,
    lifeAreaId: session.lifeAreaId.value,
    templateId: Value<String?>(session.templateId?.value),
    title: session.title,
    startedAtUtc: session.startedAtUtc,
    endedAtUtc: Value<int?>(session.endedAtUtc),
    durationSec: Value<int?>(session.durationSec),
    noteId: Value<String?>(session.noteId),
    revision: Value<int>(session.revision),
    createdAtUtc: session.createdAtUtc,
    updatedAtUtc: session.updatedAtUtc,
    deletedAtUtc: Value<int?>(session.deletedAtUtc),
  );

  static ExerciseLog exerciseLogFromRow(ExerciseLogRow row) => ExerciseLog(
    id: ExerciseLogId(row.id),
    workoutId: WorkoutSessionId(row.workoutId),
    name: row.name,
    rank: row.rank,
    notes: row.notes,
  );

  static ExerciseLogsCompanion exerciseLogToInsert(
    ExerciseLog log, {
    required String profileId,
    required int nowUtc,
  }) => ExerciseLogsCompanion.insert(
    id: log.id.value,
    profileId: profileId,
    workoutId: log.workoutId.value,
    name: log.name,
    rank: log.rank,
    notes: Value<String?>(log.notes),
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );

  static SetLog setLogFromRow(SetLogRow row) => SetLog(
    id: SetLogId(row.id),
    exerciseLogId: ExerciseLogId(row.exerciseLogId),
    rank: row.rank,
    reps: row.reps,
    weight: _measuredFrom(
      scaled: row.weightScaled,
      entered: row.weightEntered,
      unit: row.weightUnit,
    ),
    durationSec: row.durationSec,
    distance: _measuredFrom(
      scaled: row.distanceScaled,
      entered: row.distanceEntered,
      unit: row.distanceUnit,
    ),
    completedAtUtc: row.completedAtUtc,
  );

  static SetLogsCompanion setLogToInsert(
    SetLog set, {
    required String profileId,
    required int nowUtc,
  }) => SetLogsCompanion.insert(
    id: set.id.value,
    profileId: profileId,
    exerciseLogId: set.exerciseLogId.value,
    rank: set.rank,
    reps: Value<int?>(set.reps),
    weightScaled: Value<int?>(set.weight?.canonicalValue),
    weightEntered: Value<double?>(set.weight?.enteredValue.toDouble()),
    weightUnit: Value<String?>(set.weight?.enteredUnit),
    durationSec: Value<int?>(set.durationSec),
    distanceScaled: Value<int?>(set.distance?.canonicalValue),
    distanceEntered: Value<double?>(set.distance?.enteredValue.toDouble()),
    distanceUnit: Value<String?>(set.distance?.enteredUnit),
    completedAtUtc: Value<int?>(set.completedAtUtc),
    createdAtUtc: nowUtc,
  );

  // ---- body measurements --------------------------------------------------

  static BodyMeasurement measurementFromRow(BodyMeasurementRow row) =>
      BodyMeasurement(
        id: BodyMeasurementId(row.id),
        lifeAreaId: LifeAreaId(row.lifeAreaId),
        kind: BodyMeasurementKind.fromWire(row.kind),
        value: MeasuredQuantity.fromStored(
          enteredValue: row.enteredValue,
          enteredUnit: row.enteredUnit,
          canonicalValue: row.valueScaled,
        ),
        measuredAtUtc: row.measuredAtUtc,
        note: row.note,
        revision: row.revision,
        createdAtUtc: row.createdAtUtc,
        updatedAtUtc: row.updatedAtUtc,
        deletedAtUtc: row.deletedAtUtc,
      );

  static BodyMeasurementsCompanion measurementToInsert(
    BodyMeasurement measurement, {
    required String profileId,
  }) => BodyMeasurementsCompanion.insert(
    id: measurement.id.value,
    profileId: profileId,
    lifeAreaId: measurement.lifeAreaId.value,
    kind: measurement.kind.wire,
    valueScaled: measurement.value.canonicalValue,
    enteredValue: measurement.value.enteredValue.toDouble(),
    enteredUnit: measurement.value.enteredUnit,
    measuredAtUtc: measurement.measuredAtUtc,
    note: Value<String?>(measurement.note),
    revision: Value<int>(measurement.revision),
    createdAtUtc: measurement.createdAtUtc,
    updatedAtUtc: measurement.updatedAtUtc,
    deletedAtUtc: Value<int?>(measurement.deletedAtUtc),
  );

  // ---- water events -------------------------------------------------------

  static WaterEvent waterEventFromRow(WaterEventRow row) => WaterEvent(
    id: WaterEventId(row.id),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    amount: MeasuredQuantity.fromStored(
      enteredValue: row.enteredValue,
      enteredUnit: row.enteredUnit,
      canonicalValue: row.amountScaled,
    ),
    occurredAtUtc: row.occurredAtUtc,
    note: row.note,
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static WaterEventsCompanion waterEventToInsert(
    WaterEvent event, {
    required String profileId,
  }) => WaterEventsCompanion.insert(
    id: event.id.value,
    profileId: profileId,
    lifeAreaId: event.lifeAreaId.value,
    amountScaled: event.amount.canonicalValue,
    enteredValue: event.amount.enteredValue.toDouble(),
    enteredUnit: event.amount.enteredUnit,
    occurredAtUtc: event.occurredAtUtc,
    note: Value<String?>(event.note),
    revision: Value<int>(event.revision),
    createdAtUtc: event.createdAtUtc,
    updatedAtUtc: event.updatedAtUtc,
    deletedAtUtc: Value<int?>(event.deletedAtUtc),
  );

  static MeasuredQuantity? _measuredFrom({
    required int? scaled,
    required double? entered,
    required String? unit,
  }) {
    if (scaled == null || entered == null || unit == null) {
      return null;
    }
    return MeasuredQuantity.fromStored(
      enteredValue: entered,
      enteredUnit: unit,
      canonicalValue: scaled,
    );
  }
}
