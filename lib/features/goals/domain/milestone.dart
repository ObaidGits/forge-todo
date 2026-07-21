import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';

/// An immutable milestone aggregate (R-GOAL-002, R-GOAL-006).
///
/// A milestone is a strictly-owned inherited-area child of a goal: it references
/// its goal through the composite `(profile_id, goal_id)` parent key and derives
/// its Life Area from that goal (data-model §1). A milestone has a [title], an
/// optional [targetDate], a stable [rank], and a nullable [completedAtUtc].
///
/// Completion history is preserved as append-only `activity_events`
/// (`milestone_completed` / `milestone_uncompleted`); the milestone row itself
/// only records the current completion instant, so toggling completion never
/// destroys the audit trail (R-GOAL-006). Celebration on completion is a
/// presentation concern handled with reduced-motion in task 6.3.
final class Milestone {
  Milestone({
    required this.id,
    required this.profileId,
    required this.goalId,
    required this.title,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.targetDate,
    this.completedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Milestone title must not be empty.');
    }
    if (targetDate != null && !_isoDate.hasMatch(targetDate!)) {
      throw FormatException('target_date must be ISO YYYY-MM-DD.');
    }
  }

  final MilestoneId id;
  final ProfileId profileId;
  final GoalId goalId;
  final String title;

  /// Optional floating target date, ISO `YYYY-MM-DD`.
  final String? targetDate;

  /// Completion instant in UTC microseconds; null when not completed.
  final int? completedAtUtc;

  /// Stable manual ordering rank within the goal (R-GOAL-005).
  final GoalRank rank;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isCompleted => completedAtUtc != null;
  bool get isDeleted => deletedAtUtc != null;

  static final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  Milestone copyWith({
    String? title,
    Object? targetDate = _sentinel,
    Object? completedAtUtc = _sentinel,
    GoalRank? rank,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return Milestone(
      id: id,
      profileId: profileId,
      goalId: goalId,
      title: title ?? this.title,
      targetDate: targetDate == _sentinel
          ? this.targetDate
          : targetDate as String?,
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
