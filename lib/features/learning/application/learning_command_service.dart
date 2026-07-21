import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_commands.dart';

/// The learning application command surface (R-LEARN-001..004, R-GEN-005).
///
/// Every command is durable and idempotent: it carries a [CommandId] and commits
/// one atomic transaction through the shared command bus, returning the stable
/// committed result. Study-session mutations are append-only — corrections
/// append a superseding version and event, never rewriting prior facts
/// (R-LEARN-002).
abstract interface class LearningCommandService {
  /// Creates a Learning Resource (R-LEARN-001).
  Future<Result<CommittedCommandResult>> createResource({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateResourceInput input,
  });

  /// Updates a Learning Resource's fields, status, or progress config
  /// (R-LEARN-001, R-LEARN-004).
  Future<Result<CommittedCommandResult>> updateResource({
    required CommandId commandId,
    required ProfileId profileId,
    required UpdateResourceInput input,
  });

  /// Soft-deletes a Learning Resource, hiding it from search transactionally
  /// (R-GEN-003).
  Future<Result<CommittedCommandResult>> deleteResource({
    required CommandId commandId,
    required ProfileId profileId,
    required String resourceId,
  });

  /// Appends an ordered item to a resource (R-LEARN-001).
  Future<Result<CommittedCommandResult>> addItem({
    required CommandId commandId,
    required ProfileId profileId,
    required AddItemInput input,
  });

  /// Updates an item's fields (R-LEARN-001).
  Future<Result<CommittedCommandResult>> updateItem({
    required CommandId commandId,
    required ProfileId profileId,
    required UpdateItemInput input,
  });

  /// Moves an item to a new ordered position (R-LEARN-001).
  Future<Result<CommittedCommandResult>> moveItem({
    required CommandId commandId,
    required ProfileId profileId,
    required MoveItemInput input,
  });

  /// Marks an item complete at [completedAtUtc] (R-LEARN-004).
  Future<Result<CommittedCommandResult>> completeItem({
    required CommandId commandId,
    required ProfileId profileId,
    required String itemId,
    required int completedAtUtc,
  });

  /// Clears an item's completion (R-LEARN-004).
  Future<Result<CommittedCommandResult>> reopenItem({
    required CommandId commandId,
    required ProfileId profileId,
    required String itemId,
  });

  /// Logs a new immutable study session (R-LEARN-002).
  Future<Result<CommittedCommandResult>> logStudySession({
    required CommandId commandId,
    required ProfileId profileId,
    required LogStudySessionInput input,
  });

  /// Corrects a study session by appending a superseding version and event
  /// (R-LEARN-002 immutable lifecycle).
  Future<Result<CommittedCommandResult>> correctStudySession({
    required CommandId commandId,
    required ProfileId profileId,
    required CorrectStudySessionInput input,
  });
}
