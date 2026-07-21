import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/tasks/application/task_commands.dart';

/// The durable task command surface (R-GEN-005). Every method commits one
/// atomic transaction through the command bus and returns the stable committed
/// result, never a dispatch acknowledgement.
///
/// [commandId] makes each call idempotent: replaying the same id with the same
/// request returns the stored result; a different request under the same id is
/// rejected as a conflict.
abstract interface class TaskCommandService {
  /// Creates a task (R-TASK-001). The result payload carries the generated
  /// task id.
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateTaskInput input,
  });

  /// Patches an existing task (R-TASK-001, R-TASK-004, R-TASK-010).
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required UpdateTaskInput input,
  });

  /// Completes a task, preserving its due/schedule metadata (R-TASK-009).
  Future<Result<CommittedCommandResult>> complete({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });

  /// Reverses a completion through a superseding command, restoring the prior
  /// visible state and preserving audit history (R-TASK-009).
  Future<Result<CommittedCommandResult>> reopen({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });

  /// Cancels a task (R-TASK-003). A cancelled task is never overdue.
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });

  /// Moves/reorders a task, keeping the hierarchy acyclic and bounded
  /// (R-TASK-003).
  Future<Result<CommittedCommandResult>> move({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required MoveTaskInput input,
  });

  /// Completes many tasks as one atomic semantic group (R-GEN-005).
  Future<Result<CommittedCommandResult>> completeMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  });

  /// Cancels many tasks as one atomic semantic group (R-GEN-005).
  Future<Result<CommittedCommandResult>> cancelMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  });
}
