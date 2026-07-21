import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_status.dart';

/// An explicit optional value for partial updates.
///
/// The absence of an [Opt] (a `null` field) means "leave unchanged"; a present
/// `Opt(null)` means "clear this field". This distinguishes the two intents a
/// plain nullable field cannot.
final class Opt<T> {
  const Opt(this.value);
  final T value;
}

/// Input for creating a goal (R-GOAL-001, R-GOAL-002, R-GOAL-004).
///
/// Only [title] and [lifeAreaId] are required; everything else is progressively
/// disclosed. A manual goal must supply [manualProgress]; a derived goal must
/// not (its progress is computed from roadmap topics, task 6.2).
final class CreateGoalInput {
  const CreateGoalInput({
    required this.lifeAreaId,
    required this.title,
    this.outcomeMd = '',
    this.status = GoalStatus.active,
    this.targetDate,
    this.progressMode = GoalProgressMode.manual,
    this.manualProgress,
    this.noteId,
    this.tagIds = const <String>[],
  });

  final LifeAreaId lifeAreaId;
  final String title;
  final String outcomeMd;
  final GoalStatus status;
  final String? targetDate;
  final GoalProgressMode progressMode;

  /// The initial clamped `0..1` value for a manual goal. Ignored (and must be
  /// null) for a derived goal.
  final double? manualProgress;

  final NoteId? noteId;
  final List<String> tagIds;
}

/// Input for patching a goal's descriptive fields (R-GOAL-002). A `null` field
/// leaves the value unchanged; wrap clearable fields in [Opt].
final class UpdateGoalInput {
  const UpdateGoalInput({
    this.title,
    this.outcomeMd,
    this.targetDate,
    this.noteId,
    this.lifeAreaId,
  });

  final String? title;
  final String? outcomeMd;
  final Opt<String?>? targetDate;
  final Opt<NoteId?>? noteId;
  final LifeAreaId? lifeAreaId;

  bool get isEmpty =>
      title == null &&
      outcomeMd == null &&
      targetDate == null &&
      noteId == null &&
      lifeAreaId == null;
}

/// Input for setting a goal's progress strategy (R-GOAL-004).
///
/// Switching to [GoalProgressMode.manual] requires a [manualValue] (clamped to
/// `0..1`); switching to [GoalProgressMode.derived] drops any manual value and
/// computes progress from roadmap topics.
final class SetProgressPolicyInput {
  const SetProgressPolicyInput({required this.mode, this.manualValue});

  final GoalProgressMode mode;
  final double? manualValue;
}

/// Input for creating a milestone (R-GOAL-002).
final class CreateMilestoneInput {
  const CreateMilestoneInput({required this.title, this.targetDate});

  final String title;
  final String? targetDate;
}

/// Input for patching a milestone (R-GOAL-002).
final class UpdateMilestoneInput {
  const UpdateMilestoneInput({this.title, this.targetDate});

  final String? title;
  final Opt<String?>? targetDate;

  bool get isEmpty => title == null && targetDate == null;
}

/// Input for reordering a goal or milestone (R-GOAL-005).
///
/// [beforeRank]/[afterRank] are the ranks of the immediate neighbours the item
/// is placed between; the new stable rank is generated between them.
final class MoveInput {
  const MoveInput({this.beforeRank, this.afterRank});

  final String? beforeRank;
  final String? afterRank;
}
