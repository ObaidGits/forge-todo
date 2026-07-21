import 'package:forge/core/domain/id.dart';

/// The lifecycle status of a workout template.
enum WorkoutTemplateStatus {
  active('active'),
  archived('archived');

  const WorkoutTemplateStatus(this.wire);

  final String wire;

  static WorkoutTemplateStatus fromWire(String wire) {
    for (final WorkoutTemplateStatus status in WorkoutTemplateStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown workout template status: $wire');
  }
}

/// A reusable workout template: a top-level direct-area owner (R-FIT-001,
/// R-GEN-002).
///
/// A template names a workout and owns an ordered list of planned exercises
/// (stored as [TemplateExercise] children). It carries no medical
/// interpretation — only the neutral prescription a person chose to record.
final class WorkoutTemplate {
  const WorkoutTemplate({
    required this.id,
    required this.lifeAreaId,
    required this.title,
    required this.rank,
    required this.status,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.noteId,
    this.deletedAtUtc,
  });

  final WorkoutTemplateId id;
  final LifeAreaId lifeAreaId;
  final String title;
  final String rank;
  final WorkoutTemplateStatus status;

  /// Optional canonical note reference for free-form template notes.
  final String? noteId;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  WorkoutTemplate copyWith({
    String? title,
    String? rank,
    WorkoutTemplateStatus? status,
    String? noteId,
    bool clearNoteId = false,
    int? revision,
    int? updatedAtUtc,
    int? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => WorkoutTemplate(
    id: id,
    lifeAreaId: lifeAreaId,
    title: title ?? this.title,
    rank: rank ?? this.rank,
    status: status ?? this.status,
    noteId: clearNoteId ? null : (noteId ?? this.noteId),
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );
}

/// A planned exercise inside a workout template (R-FIT-001).
///
/// An exercise inherits its Life Area from its template through the composite
/// `(profile_id, template_id)` parent relationship. Targets are optional,
/// neutral hints (`targetSets`/`targetReps`); no target implies a coaching or
/// medical recommendation.
final class TemplateExercise {
  const TemplateExercise({
    required this.id,
    required this.templateId,
    required this.name,
    required this.rank,
    this.targetSets,
    this.targetReps,
    this.notes,
  });

  final TemplateExerciseId id;
  final WorkoutTemplateId templateId;
  final String name;
  final String rank;
  final int? targetSets;
  final int? targetReps;
  final String? notes;
}
