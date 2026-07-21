import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';

/// The durable reminder command surface (R-NOTIFY-001, R-GEN-005). Every method
/// commits one atomic transaction through the command bus and returns the
/// stable committed result, never a dispatch acknowledgement.
///
/// [commandId] makes each call idempotent: replaying the same id with the same
/// request returns the stored result; a different request under the same id is
/// rejected as a conflict. This is the property that makes notification actions
/// safe to retry (R-NOTIFY-005).
abstract interface class ReminderCommandService {
  /// Creates a reminder for an owner aggregate.
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required CreateReminderInput input,
  });

  /// Enables or disables a reminder (R-NOTIFY-006 per-reminder toggle).
  Future<Result<CommittedCommandResult>> setEnabled({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required bool enabled,
  });

  /// Soft-deletes a reminder.
  Future<Result<CommittedCommandResult>> delete({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
  });

  /// Commits a notification action locally (R-NOTIFY-005). The caller dismisses
  /// or reschedules the OS notification only after this returns a committed
  /// result.
  Future<Result<CommittedCommandResult>> applyAction({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required ReminderAction action,
  });
}
