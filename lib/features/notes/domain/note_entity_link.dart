import 'package:forge/core/domain/id.dart';

/// The stable relation name stored in `entity_links.relation` for a note that
/// references another domain entity (R-NOTE-002).
const String noteEntityRelation = 'note_reference';

/// The `from_type` value for a note-owned entity link.
const String noteEntityFromType = 'note';

/// The entity types a note may link to (R-NOTE-002): tasks, goals, roadmaps,
/// Learning Resources (`course`), habits, and V1 workouts. The concrete set
/// that can be created at runtime is bounded by the owner registry — a type is
/// linkable only once its owning feature registers its table so cross-profile
/// references can be rejected in the writing transaction (R-GEN-002,
/// data-model §1).
abstract final class NoteEntityTargetType {
  static const String task = 'task';
  static const String goal = 'goal';
  static const String roadmap = 'roadmap';
  static const String learningResource = 'course';
  static const String habit = 'habit';

  /// A logged workout session (V1 fitness, R-FIT-001). Matches
  /// `CanonicalEntityType.workout` so the same vocabulary threads search,
  /// links, and navigation.
  static const String workout = 'workout';

  /// Every target type the notes feature recognizes, independent of whether the
  /// owning feature is present yet.
  static const Set<String> all = <String>{
    task,
    goal,
    roadmap,
    learningResource,
    habit,
    workout,
  };
}

/// The outcome of attempting to create a note→entity link. Ownership failures
/// are distinguished so the command surface can map each to a stable
/// [Failure] and so cross-profile references are rejected explicitly
/// (R-GEN-002).
enum NoteEntityLinkOutcome {
  /// A new link row was inserted.
  linked,

  /// The link already existed (idempotent replay of the same tuple).
  alreadyLinked,

  /// The owning note is missing or trashed under this profile.
  noteMissing,

  /// The target type is not a recognized note-entity target.
  targetTypeUnknown,

  /// The target type is recognized but its owning feature is not present in
  /// this build, so ownership cannot be validated yet.
  targetTypeUnavailable,

  /// No target with that id exists under this profile — including the case
  /// where the id belongs to another profile (cross-profile rejection).
  targetMissing,
}

/// An immutable note→entity reference stored in `entity_links` (R-NOTE-002).
final class NoteEntityLink {
  const NoteEntityLink({
    required this.id,
    required this.profileId,
    required this.noteId,
    required this.targetType,
    required this.targetId,
    required this.rank,
    required this.createdAtUtc,
  });

  final String id;
  final ProfileId profileId;
  final NoteId noteId;
  final String targetType;
  final String targetId;
  final String rank;
  final int createdAtUtc;
}
