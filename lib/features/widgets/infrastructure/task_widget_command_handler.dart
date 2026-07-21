/// Routes a verified "complete task" widget command to the durable task
/// command service (R-WIDGET-003, R-GEN-005).
///
/// The [ForgeWidgetBridge] only ever hands this handler a
/// [VerifiedWidgetCommand] that already passed signature, profile-binding, and
/// freshness checks. The handler derives a STABLE command id from the intent id
/// ([VerifiedWidgetCommand.derivedCommandId]) so a double-tap or a re-delivered
/// intent maps to the same durable command and replays the same committed
/// receipt — never a duplicate completion.
library;

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';

final class TaskWidgetCommandHandler implements WidgetCommandHandler {
  const TaskWidgetCommandHandler(this._commands);

  final TaskCommandService _commands;

  @override
  bool supports(WidgetIntentAction action) =>
      action == WidgetIntentAction.completeTask;

  @override
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command) {
    return _commands.complete(
      commandId: CommandId(command.derivedCommandId),
      profileId: ProfileId(command.profileId),
      taskId: TaskId(command.targetEntityId),
    );
  }
}
