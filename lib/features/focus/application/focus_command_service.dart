import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';

/// The focus application command surface (R-FOCUS-001..005, R-GEN-005).
///
/// Every command is durable and idempotent: it carries a [CommandId] and
/// commits one atomic transaction through the shared command bus, returning the
/// stable committed result. The lifecycle is append-only — pause/resume/end
/// append events and immutable interval projections, and corrections append
/// audit events rather than rewriting history (R-FOCUS-003, R-FOCUS-005).
abstract interface class FocusCommandService {
  /// Starts a focus session, enforcing at most one open session per profile
  /// (R-FOCUS-001, R-FOCUS-003, R-FOCUS-004).
  Future<Result<CommittedCommandResult>> start({
    required CommandId commandId,
    required ProfileId profileId,
    required StartFocusSessionInput input,
  });

  /// Pauses the running session, closing the open work interval and opening a
  /// pause interval (R-FOCUS-003).
  Future<Result<CommittedCommandResult>> pause({
    required CommandId commandId,
    required ProfileId profileId,
    required PauseFocusSessionInput input,
  });

  /// Resumes the paused session, closing the pause interval and opening a new
  /// work interval anchored to the current clocks (R-FOCUS-002, R-FOCUS-003).
  Future<Result<CommittedCommandResult>> resume({
    required CommandId commandId,
    required ProfileId profileId,
    required ResumeFocusSessionInput input,
  });

  /// Ends the open session, closing its open interval and finalizing the
  /// accumulated work duration (R-FOCUS-002, R-FOCUS-003).
  Future<Result<CommittedCommandResult>> end({
    required CommandId commandId,
    required ProfileId profileId,
    required EndFocusSessionInput input,
  });

  /// Cancels (abandons) the open session (R-FOCUS-003).
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required CancelFocusSessionInput input,
  });

  /// Corrects a session's recorded duration by appending an audit event; prior
  /// history is retained (R-FOCUS-002, R-FOCUS-003, R-FOCUS-005).
  Future<Result<CommittedCommandResult>> correct({
    required CommandId commandId,
    required ProfileId profileId,
    required CorrectFocusSessionInput input,
  });
}
