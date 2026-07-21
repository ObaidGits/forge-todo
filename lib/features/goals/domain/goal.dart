import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/goal_status.dart';

/// An immutable goal aggregate (R-GOAL-001, R-GOAL-002, R-GOAL-004, R-GOAL-007).
///
/// A goal is a top-level direct-area owner: it carries `(profile_id,
/// life_area_id)` (data-model §1/§3). It has a [title], an [outcomeMd] outcome
/// statement, a [status], an optional [targetDate], notes referenced through a
/// canonical [noteId] (never an inline body, R-TASK-010 style), and a progress
/// strategy ([progressMode] + [manualProgress]). A goal MAY own at most one
/// roadmap; the roadmap schema (task 6.2) references the goal, so the linkage is
/// a seam here rather than a stored column. Unlimited goals are allowed per
/// profile with no paid gating (R-GOAL-001).
///
/// Archival ([archivedAtUtc]) is intrinsic to the goal and orthogonal to
/// [status]: archiving preserves all history and links (R-GOAL-007). Trash
/// (`deletedAtUtc`) reuses the shared deletion kernel.
final class Goal {
  Goal({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.title,
    required this.outcomeMd,
    required this.status,
    required this.progressMode,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.targetDate,
    this.manualProgress,
    this.noteId,
    this.archivedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Goal title must not be empty.');
    }
    if (targetDate != null && !_isoDate.hasMatch(targetDate!)) {
      throw FormatException('target_date must be ISO YYYY-MM-DD.');
    }
    if (manualProgress != null &&
        (manualProgress! < 0 || manualProgress! > 1)) {
      throw const FormatException('manual_progress must be within 0..1.');
    }
    if (progressMode == GoalProgressMode.manual && manualProgress == null) {
      throw const FormatException('Manual progress mode requires a value.');
    }
    if (progressMode == GoalProgressMode.derived && manualProgress != null) {
      throw const FormatException(
        'Derived progress mode must not store a manual value.',
      );
    }
  }

  final GoalId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final String title;

  /// The desired outcome as UTF-8 Markdown (R-GOAL-002).
  final String outcomeMd;

  final GoalStatus status;

  /// Optional floating target date, ISO `YYYY-MM-DD` (R-GOAL-002).
  final String? targetDate;

  final GoalProgressMode progressMode;

  /// The clamped `0..1` manual value; non-null only in manual mode (R-GOAL-004).
  final double? manualProgress;

  /// Canonical note reference (R-GOAL-002). Null when the goal has no note.
  final NoteId? noteId;

  /// Archive instant, or null when the goal is not archived (R-GOAL-007).
  final int? archivedAtUtc;

  /// Stable manual ordering rank (R-GOAL-005).
  final GoalRank rank;

  /// Semantic revision, incremented on each semantic row change (data-model §1).
  final int revision;

  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isArchived => archivedAtUtc != null;
  bool get isDeleted => deletedAtUtc != null;

  /// The manual progress surface. For derived goals, callers must instead use
  /// [GoalProgressPolicy.derived] with the goal's roadmap topic leaves (task
  /// 6.2), because the goal aggregate does not hold the roadmap.
  GoalProgress get manualProgressSurface =>
      GoalProgressPolicy.manual(manualProgress);

  static final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  Goal copyWith({
    String? title,
    String? outcomeMd,
    GoalStatus? status,
    Object? targetDate = _sentinel,
    GoalProgressMode? progressMode,
    Object? manualProgress = _sentinel,
    Object? noteId = _sentinel,
    Object? archivedAtUtc = _sentinel,
    GoalRank? rank,
    LifeAreaId? lifeAreaId,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return Goal(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId ?? this.lifeAreaId,
      title: title ?? this.title,
      outcomeMd: outcomeMd ?? this.outcomeMd,
      status: status ?? this.status,
      targetDate: targetDate == _sentinel
          ? this.targetDate
          : targetDate as String?,
      progressMode: progressMode ?? this.progressMode,
      manualProgress: manualProgress == _sentinel
          ? this.manualProgress
          : manualProgress as double?,
      noteId: noteId == _sentinel ? this.noteId : noteId as NoteId?,
      archivedAtUtc: archivedAtUtc == _sentinel
          ? this.archivedAtUtc
          : archivedAtUtc as int?,
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
