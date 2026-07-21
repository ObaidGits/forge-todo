import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';

/// An immutable checklist item aggregate (R-GOAL-003, R-GOAL-004).
///
/// A checklist item is a strictly-owned inherited-area child of a roadmap
/// topic: it references the topic through the composite
/// `(profile_id, roadmap_topic_id)` parent key (data-model §1). It has free
/// [text], a nullable [checkedAtUtc] instant, and a stable ordering [rank]
/// (R-GOAL-005).
///
/// A checklist item **never contributes independently** to derived progress
/// (R-GOAL-004): only roadmap topics are weighted leaves, which prevents double
/// counting. Checklist items are a within-topic breakdown for the user, not a
/// progress source.
final class ChecklistItem {
  ChecklistItem({
    required this.id,
    required this.profileId,
    required this.roadmapTopicId,
    required this.text,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.checkedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (text.trim().isEmpty) {
      throw const FormatException('Checklist item text must not be empty.');
    }
  }

  final ChecklistItemId id;
  final ProfileId profileId;
  final RoadmapTopicId roadmapTopicId;
  final String text;

  /// Instant the item was checked, in UTC microseconds; null when unchecked.
  final int? checkedAtUtc;

  /// Stable manual ordering rank within the topic (R-GOAL-005).
  final GoalRank rank;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isChecked => checkedAtUtc != null;
  bool get isDeleted => deletedAtUtc != null;

  ChecklistItem copyWith({
    String? text,
    Object? checkedAtUtc = _sentinel,
    GoalRank? rank,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return ChecklistItem(
      id: id,
      profileId: profileId,
      roadmapTopicId: roadmapTopicId,
      text: text ?? this.text,
      checkedAtUtc: checkedAtUtc == _sentinel
          ? this.checkedAtUtc
          : checkedAtUtc as int?,
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
