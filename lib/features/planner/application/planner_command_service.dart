import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_commands.dart';

/// The planner application command surface (R-PLAN-001..004).
///
/// Every command is durable and idempotent: it carries a [CommandId] and
/// commits one atomic transaction through the shared command bus, returning the
/// stable committed result (R-GEN-005). The planner feature exclusively owns
/// `planning_periods`, `planning_entries`, `planning_close_events`,
/// `planning_close_items`, and `planning_close_adjustments`; other features
/// reach them only through this contract (data-model §1).
abstract interface class PlannerCommandService {
  /// Creates or updates the single area-scoped planning record addressed by the
  /// composite key in [input] (R-PLAN-001, R-PLAN-004).
  Future<Result<CommittedCommandResult>> savePlanningRecord({
    required CommandId commandId,
    required ProfileId profileId,
    required SavePlanningRecordInput input,
  });

  /// Adds a `planned` reference from a planning record to a task/goal/habit/note
  /// (R-PLAN-002).
  Future<Result<CommittedCommandResult>> addReference({
    required CommandId commandId,
    required ProfileId profileId,
    required AddReferenceInput input,
  });

  /// Removes a reference from a planning record.
  Future<Result<CommittedCommandResult>> removeReference({
    required CommandId commandId,
    required ProfileId profileId,
    required String entryId,
  });

  /// Carries selected incomplete references forward into a target period,
  /// recording the carry-forward relation without altering task due dates
  /// (R-PLAN-003).
  Future<Result<CommittedCommandResult>> applyCarryForward({
    required CommandId commandId,
    required ProfileId profileId,
    required CarryForwardInput input,
  });

  /// Takes the single immutable factual close of a planning period. Retrying
  /// the same command is idempotent and never creates a second close
  /// (R-PLAN-003).
  Future<Result<CommittedCommandResult>> closePeriod({
    required CommandId commandId,
    required ProfileId profileId,
    required ClosePeriodInput input,
  });

  /// Appends a linked source-correction adjustment to an immutable factual
  /// close (R-PLAN-003, R-HABIT-005).
  Future<Result<CommittedCommandResult>> appendSourceCorrection({
    required CommandId commandId,
    required ProfileId profileId,
    required SourceCorrectionInput input,
  });

  /// Appends a derived policy-recomputation adjustment to an immutable factual
  /// close. It never creates or replaces a factual close (R-PLAN-003).
  Future<Result<CommittedCommandResult>> appendPolicyRecomputation({
    required CommandId commandId,
    required ProfileId profileId,
    required PolicyRecomputationInput input,
  });
}
