/// Input value objects for durable fitness commands (R-FIT-001, R-FIT-002).
///
/// The measured fields (`weight`, `distance`, body-weight `value`) carry the
/// entered numeric value and unit verbatim; the service derives and stores the
/// canonical amount while preserving what was entered.
library;

/// A planned exercise for a new workout template (R-FIT-001).
final class TemplateExerciseInput {
  const TemplateExerciseInput({
    required this.name,
    required this.rank,
    this.targetSets,
    this.targetReps,
    this.notes,
  });

  final String name;
  final String rank;
  final int? targetSets;
  final int? targetReps;
  final String? notes;
}

/// Input to create a workout template with its planned exercises (R-FIT-001).
final class CreateWorkoutTemplateInput {
  const CreateWorkoutTemplateInput({
    required this.lifeAreaId,
    required this.title,
    required this.rank,
    this.noteId,
    this.exercises = const <TemplateExerciseInput>[],
  });

  final String lifeAreaId;
  final String title;
  final String rank;
  final String? noteId;
  final List<TemplateExerciseInput> exercises;
}

/// A single performed set within a logged exercise (R-FIT-001, R-FIT-002).
///
/// `weightValue`/`weightUnit` and `distanceValue`/`distanceUnit` are entered
/// verbatim and preserved; each is all-or-nothing (both present or both
/// absent). `durationSec` is canonical seconds.
final class SetLogInput {
  const SetLogInput({
    required this.rank,
    this.reps,
    this.weightValue,
    this.weightUnit,
    this.durationSec,
    this.distanceValue,
    this.distanceUnit,
    this.completedAtUtc,
  });

  final String rank;
  final int? reps;
  final num? weightValue;
  final String? weightUnit;
  final int? durationSec;
  final num? distanceValue;
  final String? distanceUnit;
  final int? completedAtUtc;
}

/// A performed exercise within a logged session (R-FIT-001).
final class ExerciseLogInput {
  const ExerciseLogInput({
    required this.name,
    required this.rank,
    this.notes,
    this.sets = const <SetLogInput>[],
  });

  final String name;
  final String rank;
  final String? notes;
  final List<SetLogInput> sets;
}

/// Input to log a workout session with its exercises and sets (R-FIT-001).
final class LogWorkoutSessionInput {
  const LogWorkoutSessionInput({
    required this.lifeAreaId,
    required this.title,
    required this.startedAtUtc,
    this.templateId,
    this.endedAtUtc,
    this.durationSec,
    this.noteId,
    this.exercises = const <ExerciseLogInput>[],
  });

  final String lifeAreaId;
  final String title;
  final int startedAtUtc;
  final String? templateId;
  final int? endedAtUtc;
  final int? durationSec;
  final String? noteId;
  final List<ExerciseLogInput> exercises;
}

/// Input to record a body-weight measurement (R-FIT-002).
///
/// [value]/[unit] are preserved exactly; the service derives the canonical
/// amount for computation and cross-unit history.
final class RecordBodyMeasurementInput {
  const RecordBodyMeasurementInput({
    required this.lifeAreaId,
    required this.value,
    required this.unit,
    required this.measuredAtUtc,
    this.note,
  });

  final String lifeAreaId;
  final num value;
  final String unit;
  final int measuredAtUtc;
  final String? note;
}

/// Input to log an optional water-intake event (R-FIT-003).
///
/// [value]/[unit] are a neutral volume (ml/l/fl oz/...) preserved exactly; the
/// service derives the canonical microlitre amount for computation and
/// cross-unit history. Logging is only accepted while water tracking is
/// enabled for the profile (disabled by default).
final class LogWaterEventInput {
  const LogWaterEventInput({
    required this.lifeAreaId,
    required this.value,
    required this.unit,
    required this.occurredAtUtc,
    this.note,
  });

  final String lifeAreaId;
  final num value;
  final String unit;
  final int occurredAtUtc;
  final String? note;
}
