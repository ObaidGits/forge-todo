import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';

/// A logged workout session: a top-level direct-area owner (R-FIT-001,
/// R-GEN-002).
///
/// A session records when a workout happened and owns the exercises and sets
/// that were performed. It may optionally reference the [templateId] it was
/// derived from; the template is never mutated by logging a session.
final class WorkoutSession {
  const WorkoutSession({
    required this.id,
    required this.lifeAreaId,
    required this.title,
    required this.startedAtUtc,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.templateId,
    this.endedAtUtc,
    this.durationSec,
    this.noteId,
    this.deletedAtUtc,
  });

  final WorkoutSessionId id;
  final LifeAreaId lifeAreaId;
  final String title;

  /// Optional template this session was started from (R-FIT-001).
  final WorkoutTemplateId? templateId;

  final int startedAtUtc;
  final int? endedAtUtc;

  /// Optional explicit duration in seconds; independent of start/end so a
  /// person may log a duration without exact instants.
  final int? durationSec;

  /// Optional canonical note reference for free-form session notes.
  final String? noteId;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  WorkoutSession copyWith({
    String? title,
    int? endedAtUtc,
    bool clearEndedAt = false,
    int? durationSec,
    bool clearDuration = false,
    String? noteId,
    bool clearNoteId = false,
    int? revision,
    int? updatedAtUtc,
    int? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => WorkoutSession(
    id: id,
    lifeAreaId: lifeAreaId,
    title: title ?? this.title,
    templateId: templateId,
    startedAtUtc: startedAtUtc,
    endedAtUtc: clearEndedAt ? null : (endedAtUtc ?? this.endedAtUtc),
    durationSec: clearDuration ? null : (durationSec ?? this.durationSec),
    noteId: clearNoteId ? null : (noteId ?? this.noteId),
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );
}

/// A performed exercise within a session (R-FIT-001). Inherits its Life Area
/// from the owning session through the composite `(profile_id, workout_id)`
/// parent relationship.
final class ExerciseLog {
  const ExerciseLog({
    required this.id,
    required this.workoutId,
    required this.name,
    required this.rank,
    this.notes,
  });

  final ExerciseLogId id;
  final WorkoutSessionId workoutId;
  final String name;
  final String rank;
  final String? notes;
}

/// A single performed set within an exercise log (R-FIT-001, R-FIT-002).
///
/// Repetitions are a plain count; [weight] and [distance] are [MeasuredQuantity]
/// values that preserve the exact entered unit while carrying a canonical
/// amount, and [durationSec] is canonical seconds. Every measured field is
/// optional so bodyweight sets, timed holds, and distance efforts are all
/// representable without medical framing.
final class SetLog {
  const SetLog({
    required this.id,
    required this.exerciseLogId,
    required this.rank,
    this.reps,
    this.weight,
    this.durationSec,
    this.distance,
    this.completedAtUtc,
  });

  final SetLogId id;
  final ExerciseLogId exerciseLogId;
  final String rank;
  final int? reps;
  final MeasuredQuantity? weight;
  final int? durationSec;
  final MeasuredQuantity? distance;
  final int? completedAtUtc;
}
