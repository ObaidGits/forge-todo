import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/tasks/application/recurrence_commands.dart';

/// The durable recurrence command surface (R-TASK-005, R-TASK-006, R-TASK-007,
/// R-GEN-005).
///
/// Every method commits one atomic transaction through the command bus and
/// returns the stable committed result. [commandId] makes each call idempotent:
/// replaying the same id with the same request returns the stored result; a
/// different request under the same id is rejected as a conflict.
abstract interface class RecurrenceCommandService {
  /// Attaches or replaces the recurrence of [taskId], creating the first
  /// immutable schedule version and materializing its first occurrence
  /// (R-TASK-005).
  Future<Result<CommittedCommandResult>> setRecurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required SetRecurrenceInput input,
  });

  /// Completes the current open occurrence of a recurring [taskId]: appends
  /// immutable occurrence history and resolves the next deterministic
  /// occurrence without rewriting the schedule version that generated history
  /// (R-TASK-006).
  Future<Result<CommittedCommandResult>> completeOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });

  /// Edits the recurrence of [taskId] with "this occurrence" or "this and
  /// future" scope (R-TASK-007). The latter closes the current schedule version
  /// and creates a successor at the effective occurrence key.
  Future<Result<CommittedCommandResult>> editRecurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required EditRecurrenceInput input,
  });

  /// Appends a superseding event that restores the prior visible state of the
  /// most recent occurrence event for [taskId] (R-TASK-007, R-TASK-009).
  /// Generated historical keys and events stay immutable.
  Future<Result<CommittedCommandResult>> undoLastOccurrenceChange({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  });
}
