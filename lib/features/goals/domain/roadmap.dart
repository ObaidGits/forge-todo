import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/roadmap_status.dart';

/// An immutable roadmap aggregate (R-GOAL-001, R-GOAL-003).
///
/// A roadmap details exactly one goal: each goal MAY own at most one roadmap
/// and standalone roadmaps are not supported in V1 (R-GOAL-001). The roadmap is
/// a strictly-owned inherited-area child of its goal — it references the goal
/// through the composite `(profile_id, goal_id)` parent key and derives its
/// Life Area from that goal (data-model §1). The "at most one" rule is enforced
/// by a unique index on `(profile_id, goal_id)`.
///
/// A roadmap contains ordered [RoadmapSection]s; sections contain ordered
/// topics. Derived progress is never stored on the roadmap; it is recomputed
/// from the roadmap's topics as weighted leaves (R-GOAL-004).
final class Roadmap {
  Roadmap({
    required this.id,
    required this.profileId,
    required this.goalId,
    required this.title,
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.targetDate,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Roadmap title must not be empty.');
    }
    if (targetDate != null && !_isoDate.hasMatch(targetDate!)) {
      throw FormatException('target_date must be ISO YYYY-MM-DD.');
    }
  }

  final RoadmapId id;
  final ProfileId profileId;
  final GoalId goalId;
  final String title;
  final RoadmapStatus status;

  /// Optional floating target date, ISO `YYYY-MM-DD`.
  final String? targetDate;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  static final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  Roadmap copyWith({
    String? title,
    RoadmapStatus? status,
    Object? targetDate = _sentinel,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return Roadmap(
      id: id,
      profileId: profileId,
      goalId: goalId,
      title: title ?? this.title,
      status: status ?? this.status,
      targetDate: targetDate == _sentinel
          ? this.targetDate
          : targetDate as String?,
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
