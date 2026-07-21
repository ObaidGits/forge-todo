import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_commands.dart';

/// The durable habit command surface (R-HABIT-001..007, R-GEN-005).
///
/// Every method commits one atomic transaction through the command bus and
/// returns the stable committed result. [commandId] makes each call idempotent:
/// replaying the same id with the same request returns the stored result; a
/// different request under the same id is rejected as a conflict.
abstract interface class HabitCommandService {
  /// Creates a habit, its first immutable schedule + target version, and
  /// materializes the first occurrence (R-HABIT-001).
  Future<Result<CommittedCommandResult>> createHabit({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CreateHabitInput input,
  });

  /// Records an append-only check-in against the occurrence for the given date
  /// and re-derives its projection (R-HABIT-003). Rejects observations that
  /// violate the bound target's kind (e.g. a value on a boolean target,
  /// incompatible units, or a negative value).
  Future<Result<CommittedCommandResult>> checkIn({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CheckInInput input,
  });

  /// Appends a superseding correction of a prior observation (R-HABIT-005).
  Future<Result<CommittedCommandResult>> correctObservation({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CorrectObservationInput input,
  });

  /// Skips an occurrence with a reason (R-HABIT-004, R-HABIT-005).
  Future<Result<CommittedCommandResult>> skipOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required SkipOccurrenceInput input,
  });

  /// Closes a dated occurrence or aggregate period, finalizing its projection
  /// (R-HABIT-002, R-HABIT-003).
  Future<Result<CommittedCommandResult>> closeOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required CloseOccurrenceInput input,
  });

  /// Edits schedule/target "this and future" by closing the current version and
  /// creating a successor at the effective key (R-HABIT-003).
  Future<Result<CommittedCommandResult>> editSchedule({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required EditScheduleInput input,
  });

  /// Pauses a habit from a start date (R-HABIT-005).
  Future<Result<CommittedCommandResult>> pauseHabit({
    required CommandId commandId,
    required ProfileId profileId,
    required HabitId habitId,
    required PauseHabitInput input,
  });
}
