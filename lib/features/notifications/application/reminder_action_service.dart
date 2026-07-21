import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/notification_transport.dart';
import 'package:forge/features/notifications/application/reminder_command_service.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';

/// The committed result of handling a notification action (R-NOTIFY-005).
final class ReminderActionResult {
  const ReminderActionResult({
    required this.committed,
    required this.dismissed,
  });

  /// The stable committed result of the durable action command.
  final CommittedCommandResult committed;

  /// Whether the OS notification was dismissed/cancelled after the commit.
  final bool dismissed;
}

/// Orchestrates idempotent notification actions (R-NOTIFY-005, R-GEN-005).
///
/// The invariant enforced here is ordering: the durable local effect is
/// committed through the command bus *before* the OS notification is dismissed
/// or rescheduled. Because every command is keyed by a stable [commandId], a
/// retried or duplicated action returns the same committed result and creates
/// no duplicate effect.
final class ReminderActionService {
  const ReminderActionService({
    required this.reminderCommands,
    required this.transport,
    this.taskCommands,
  });

  final ReminderCommandService reminderCommands;
  final NotificationTransport transport;

  /// Optional owner command service used to complete a task-owned reminder.
  final TaskCommandService? taskCommands;

  Future<Result<ReminderActionResult>> handle({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required ReminderOwnerType ownerType,
    required String ownerId,
    required ReminderAction action,
  }) async {
    // 1. Persist the reminder-side effect first (never dismiss before commit).
    final Result<CommittedCommandResult> reminderResult = await reminderCommands
        .applyAction(
          commandId: commandId,
          profileId: profileId,
          reminderId: reminderId,
          action: action,
        );
    if (reminderResult is Failed<CommittedCommandResult>) {
      return Failed<ReminderActionResult>(reminderResult.failure);
    }
    final CommittedCommandResult committed =
        (reminderResult as Success<CommittedCommandResult>).value;

    // 2. Owner completion, when requested and supported. Uses a deterministic
    //    derived command id so the whole handle is idempotent on replay.
    if (action.kind == ReminderActionKind.complete &&
        ownerType == ReminderOwnerType.task &&
        taskCommands != null) {
      final Result<CommittedCommandResult> ownerResult = await taskCommands!
          .complete(
            commandId: CommandId('${commandId.value}-owner'),
            profileId: profileId,
            taskId: TaskId(ownerId),
          );
      if (ownerResult is Failed<CommittedCommandResult>) {
        return Failed<ReminderActionResult>(ownerResult.failure);
      }
    }

    // 3. Only now dismiss/cancel the OS notification. Snooze reschedules on the
    //    next reconciliation, so it also cancels the current placement.
    final bool dismissed = await transport.cancel(reminderId.value);

    return Success<ReminderActionResult>(
      ReminderActionResult(committed: committed, dismissed: dismissed),
    );
  }
}
