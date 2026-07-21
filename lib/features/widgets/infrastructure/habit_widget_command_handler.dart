/// Routes a verified "check in habit" widget command to the durable habit
/// command service (R-WIDGET-003, R-HABIT-003, R-GEN-005).
///
/// Like the task handler, this only receives an already-verified command and
/// derives a STABLE command id from the intent id so a re-delivered tap replays
/// the same committed receipt instead of double-recording a check-in. The
/// check-in date is the trusted current local date derived from the injected
/// [Clock]; the widget never carries a date so a replayed tap always resolves
/// to the same occurrence via the idempotent command id.
library;

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';

final class HabitWidgetCommandHandler implements WidgetCommandHandler {
  const HabitWidgetCommandHandler(this._commands, this._clock);

  final HabitCommandService _commands;
  final Clock _clock;

  @override
  bool supports(WidgetIntentAction action) =>
      action == WidgetIntentAction.checkInHabit;

  @override
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command) {
    final DateTime nowUtc = _clock.utcNow().toUtc();
    final LocalDate today = LocalDate.parse(
      '${nowUtc.year.toString().padLeft(4, '0')}-'
      '${nowUtc.month.toString().padLeft(2, '0')}-'
      '${nowUtc.day.toString().padLeft(2, '0')}',
    );
    return _commands.checkIn(
      commandId: CommandId(command.derivedCommandId),
      profileId: ProfileId(command.profileId),
      habitId: HabitId(command.targetEntityId),
      input: CheckInInput(
        onDate: today,
        kind: ObservationInputKind.booleanTrue,
      ),
    );
  }
}
