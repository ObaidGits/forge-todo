import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/domain/goal_status.dart';

/// The durable goal command surface (R-GEN-005). Every method commits one
/// atomic transaction through the command bus and returns the stable committed
/// result, never a dispatch acknowledgement.
///
/// [commandId] makes each call idempotent: replaying the same id with the same
/// request returns the stored result; a different request under the same id is
/// rejected as a conflict.
abstract interface class GoalCommandService {
  /// Creates a goal (R-GOAL-001, R-GOAL-002). The result payload carries the
  /// generated goal id.
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateGoalInput input,
  });

  /// Patches a goal's descriptive fields (R-GOAL-002).
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required UpdateGoalInput input,
  });

  /// Sets a goal's lifecycle status (R-GOAL-002).
  Future<Result<CommittedCommandResult>> setStatus({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required GoalStatus status,
  });

  /// Sets a goal's progress strategy: manual (clamped `0..1`) or derived
  /// (roadmap topics) (R-GOAL-004).
  Future<Result<CommittedCommandResult>> setProgressPolicy({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required SetProgressPolicyInput input,
  });

  /// Updates a manual goal's clamped `0..1` progress value (R-GOAL-004).
  Future<Result<CommittedCommandResult>> setManualProgress({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required double value,
  });

  /// Archives or unarchives a goal, preserving all history and links
  /// (R-GOAL-007).
  Future<Result<CommittedCommandResult>> setArchived({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required bool archived,
  });

  /// Reorders a goal among its siblings (R-GOAL-005).
  Future<Result<CommittedCommandResult>> move({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required MoveInput input,
  });

  /// Adds a milestone to a goal (R-GOAL-002). The result payload carries the
  /// generated milestone id.
  Future<Result<CommittedCommandResult>> addMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required CreateMilestoneInput input,
  });

  /// Patches a milestone (R-GOAL-002).
  Future<Result<CommittedCommandResult>> updateMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
    required UpdateMilestoneInput input,
  });

  /// Marks a milestone completed, appending completion history (R-GOAL-006).
  Future<Result<CommittedCommandResult>> completeMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
  });

  /// Reverses a milestone completion through a superseding command; prior
  /// completion history remains in the append-only activity feed (R-GOAL-006).
  Future<Result<CommittedCommandResult>> uncompleteMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
  });

  /// Reorders a milestone within its goal (R-GOAL-005).
  Future<Result<CommittedCommandResult>> moveMilestone({
    required CommandId commandId,
    required ProfileId profileId,
    required MilestoneId milestoneId,
    required MoveInput input,
  });
}
