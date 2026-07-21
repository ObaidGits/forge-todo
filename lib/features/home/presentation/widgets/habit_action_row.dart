import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:go_router/go_router.dart';

/// A single Today habit check-in row rendered by Home (R-HOME-001, R-HOME-003,
/// R-HABIT-003, R-HABIT-006).
///
/// Home owns this row rather than importing the habits presentation, keeping
/// the cross-feature dependency on the habits *application* contract only
/// (design.md §4/§16). The control adapts to the target kind: a boolean toggles
/// done inline, a count adds one toward its target, and a duration/quantity or
/// abstinence habit opens its detail surface for the richer entry. Copy is
/// neutral and non-shaming — a not-yet-logged occurrence is stated plainly, a
/// paused one is a calm chip, never a personal failure (R-HABIT-006).
final class HabitActionRow extends ConsumerWidget {
  const HabitActionRow({required this.slot, super.key});

  final HabitOccurrenceSlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: ValueKey<String>('home-habit-${slot.habitId}'),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: _leading(context, ref),
        title: Text(slot.title),
        subtitle: Text(
          slot.isPaused ? context.l10n.homeHabitPaused : _statusText(context),
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/habits/${slot.habitId}'),
      ),
    );
  }

  String _statusText(BuildContext context) {
    if (slot.isCompleted) {
      return context.l10n.homeHabitDone;
    }
    if (slot.isNumeric && slot.targetValue != null) {
      return '${slot.normalizedTotal}/${slot.targetValue}';
    }
    return context.l10n.homeSectionHabits;
  }

  Widget _leading(BuildContext context, WidgetRef ref) {
    if (slot.isPaused) {
      return const Icon(Icons.pause_circle_outline);
    }
    switch (slot.targetKindWire) {
      case kHabitTargetBoolean:
        return Semantics(
          container: true,
          checked: slot.isCompleted,
          label: context.l10n.homeHabitMarkDone(slot.title),
          child: ExcludeSemantics(
            child: Checkbox(
              value: slot.isCompleted,
              // Check-ins are append-only; once done the boolean stays done.
              onChanged: slot.isCompleted
                  ? null
                  : (bool? value) {
                      if (value ?? false) {
                        unawaited(_markBooleanDone(ref));
                      }
                    },
            ),
          ),
        );
      case kHabitTargetCount:
        return IconButton(
          icon: const Icon(Icons.add_circle_outline),
          tooltip: context.l10n.homeHabitAddProgress(slot.title),
          onPressed: () => unawaited(_addCount(ref)),
        );
      default:
        // Duration/quantity/abstinence open the detail surface for the richer
        // entry rather than a Today dialog.
        return IconButton(
          icon: const Icon(Icons.open_in_new),
          tooltip: context.l10n.homeHabitOpen(slot.title),
          onPressed: () => unawaited(context.push('/habits/${slot.habitId}')),
        );
    }
  }

  Future<void> _markBooleanDone(WidgetRef ref) {
    return ref
        .read(homeControllerProvider.notifier)
        .checkInHabit(
          habitId: slot.habitId,
          onDateIso: slot.onDateIso,
          kind: ObservationInputKind.booleanTrue,
        );
  }

  Future<void> _addCount(WidgetRef ref) {
    return ref
        .read(homeControllerProvider.notifier)
        .checkInHabit(
          habitId: slot.habitId,
          onDateIso: slot.onDateIso,
          kind: ObservationInputKind.value,
          rawValue: 1,
        );
  }
}
