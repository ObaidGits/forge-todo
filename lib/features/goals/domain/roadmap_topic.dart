import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

/// An immutable roadmap topic aggregate (R-GOAL-003, R-GOAL-004).
///
/// A topic is a strictly-owned inherited-area child of a section: it references
/// the section through the composite `(profile_id, section_id)` parent key
/// (data-model §1). Topics are the **only** weighted progress leaves of a
/// roadmap (R-GOAL-004). A topic MAY carry checklist items, linked
/// tasks/notes/Learning Resources (through `entity_links`), an [estimateSec]
/// estimate, a [status], and a nonnegative completion [weight] (R-GOAL-003).
///
/// The [weight] is nullable: a null weight normalizes to `1` for progress
/// (R-GOAL-004). A negative weight is rejected at construction. The topic's
/// canonical note is referenced through [noteId] only — never an inline body.
final class RoadmapTopic {
  RoadmapTopic({
    required this.id,
    required this.profileId,
    required this.sectionId,
    required this.title,
    required this.status,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.weight,
    this.estimateSec,
    this.noteId,
    this.completedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Roadmap topic title must not be empty.');
    }
    if (weight != null && weight! < 0) {
      throw const FormatException('Topic weight must be nonnegative.');
    }
    if (estimateSec != null && estimateSec! < 0) {
      throw const FormatException('Topic estimate must be nonnegative.');
    }
  }

  final RoadmapTopicId id;
  final ProfileId profileId;
  final RoadmapSectionId sectionId;
  final String title;
  final RoadmapTopicStatus status;

  /// The topic's nonnegative completion weight, or null to normalize to `1`
  /// (R-GOAL-004).
  final num? weight;

  /// Optional estimate in whole seconds (R-GOAL-003).
  final int? estimateSec;

  /// Canonical note reference (R-GOAL-003). Null when the topic has no note.
  final NoteId? noteId;

  /// Completion instant in UTC microseconds; null when not completed.
  final int? completedAtUtc;

  /// Stable manual ordering rank within the section (R-GOAL-005).
  final GoalRank rank;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  /// True when the topic contributes to derived progress (R-GOAL-004): live and
  /// neither archived nor cancelled.
  bool get isEligible => !isDeleted && status.isEligible;

  bool get isCompleted => status.isCompleted;

  /// Projects this topic onto the goal-side derived-progress leaf (R-GOAL-004).
  ///
  /// This is the single seam that feeds roadmap topics into the shared
  /// [GoalProgressPolicy.derived] computation, so the policy never needs to
  /// know the roadmap schema and no other entity contributes independently.
  GoalProgressLeaf toProgressLeaf() => GoalProgressLeaf(
    eligible: isEligible,
    completed: isCompleted,
    weight: weight,
  );

  RoadmapTopic copyWith({
    String? title,
    RoadmapTopicStatus? status,
    Object? weight = _sentinel,
    Object? estimateSec = _sentinel,
    Object? noteId = _sentinel,
    Object? completedAtUtc = _sentinel,
    GoalRank? rank,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return RoadmapTopic(
      id: id,
      profileId: profileId,
      sectionId: sectionId,
      title: title ?? this.title,
      status: status ?? this.status,
      weight: weight == _sentinel ? this.weight : weight as num?,
      estimateSec: estimateSec == _sentinel
          ? this.estimateSec
          : estimateSec as int?,
      noteId: noteId == _sentinel ? this.noteId : noteId as NoteId?,
      completedAtUtc: completedAtUtc == _sentinel
          ? this.completedAtUtc
          : completedAtUtc as int?,
      rank: rank ?? this.rank,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  /// Passed to [copyWith] for a clearable field to mean "leave unchanged".
  static const Object unchanged = _sentinel;

  static const Object _sentinel = Object();
}
