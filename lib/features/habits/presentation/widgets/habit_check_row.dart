import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// A single Today habit check-in row (R-HOME-001, R-HOME-003, R-HABIT-003).
///
/// The control adapts to the target kind: a boolean toggles done, a numeric
/// kind adds toward its target, and an abstinence habit logs a slip neutrally.
/// Every interactive control carries an accessible name (NFR-A11Y-001) and the
/// copy is non-shaming — a not-yet-logged occurrence is stated plainly, never as
/// a personal failure (R-HABIT-006).
final class HabitCheckRow extends ConsumerWidget {
  const HabitCheckRow({required this.entry, super.key});

  final HabitTodayEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String status = HabitLabels.occurrenceStatus(
      l10n,
      entry.statusWire,
      isPaused: entry.isPaused,
    );
    final String progress = HabitLabels.targetProgress(l10n, entry);
    final String subtitle = progress.isEmpty ? status : '$status · $progress';

    return Card(
      key: ValueKey<String>('habit-row-${entry.habitId}'),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: _leading(context, ref, l10n),
        title: Text(entry.title),
        subtitle: Text(
          entry.isPaused ? l10n.habitPausedNote : subtitle,
          style: theme.textTheme.bodySmall,
        ),
        trailing: _menu(context, ref, l10n),
        onTap: () => context.push('/habits/${entry.habitId}'),
      ),
    );
  }

  Widget _leading(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    if (entry.isPaused) {
      return const Icon(Icons.pause_circle_outline);
    }
    switch (entry.targetKindWire) {
      case kHabitTargetBoolean:
        return Semantics(
          container: true,
          checked: entry.isCompleted,
          label: l10n.habitCheckMarkDone(entry.title),
          child: ExcludeSemantics(
            child: Checkbox(
              value: entry.isCompleted,
              // Check-ins are append-only; once done the boolean stays done.
              onChanged: entry.isCompleted
                  ? null
                  : (bool? value) {
                      if (value ?? false) {
                        unawaited(_markBooleanDone(ref));
                      }
                    },
            ),
          ),
        );
      case kHabitTargetAbstinence:
        return Icon(
          entry.isCompleted
              ? Icons.check_circle_outline
              : Icons.shield_outlined,
        );
      default:
        return IconButton(
          icon: const Icon(Icons.add_circle_outline),
          tooltip: l10n.habitAddEntryTo(entry.title),
          onPressed: () => unawaited(_addNumeric(context, ref)),
        );
    }
  }

  Widget _menu(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    return PopupMenuButton<String>(
      tooltip: l10n.habitMoreActions(entry.title),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (entry.targetKindWire == kHabitTargetAbstinence && !entry.isPaused)
          PopupMenuItem<String>(
            value: 'slip',
            child: Text(l10n.habitRecordSlip),
          ),
        if (!entry.isPaused && !entry.isSkipped)
          PopupMenuItem<String>(value: 'skip', child: Text(l10n.habitSkip)),
        PopupMenuItem<String>(
          value: 'view',
          child: Text(l10n.habitViewDetails),
        ),
      ],
      onSelected: (String value) {
        switch (value) {
          case 'slip':
            unawaited(_recordSlip(ref));
          case 'skip':
            unawaited(_skip(ref));
          case 'view':
            unawaited(context.push('/habits/${entry.habitId}'));
        }
      },
    );
  }

  LocalDate get _onDate => LocalDate.parse(entry.onDateIso);

  Future<void> _markBooleanDone(WidgetRef ref) {
    return ref
        .read(habitActionsProvider.notifier)
        .checkIn(
          habitId: entry.habitId,
          onDate: _onDate,
          kind: ObservationInputKind.booleanTrue,
        );
  }

  Future<void> _recordSlip(WidgetRef ref) {
    return ref
        .read(habitActionsProvider.notifier)
        .checkIn(
          habitId: entry.habitId,
          onDate: _onDate,
          kind: ObservationInputKind.violation,
        );
  }

  Future<void> _skip(WidgetRef ref) {
    return ref
        .read(habitActionsProvider.notifier)
        .skip(habitId: entry.habitId, onDate: _onDate);
  }

  Future<void> _addNumeric(BuildContext context, WidgetRef ref) async {
    // Count targets accumulate one observation per tap; duration and quantity
    // ask for an amount in their unit.
    if (entry.targetKindWire == kHabitTargetCount) {
      await ref
          .read(habitActionsProvider.notifier)
          .checkIn(
            habitId: entry.habitId,
            onDate: _onDate,
            kind: ObservationInputKind.value,
            rawValue: 1,
          );
      return;
    }
    final num? amount = await showDialog<num>(
      context: context,
      builder: (BuildContext context) =>
          _AmountDialog(title: entry.title, unit: _unit(context.l10n)),
    );
    if (amount == null) {
      return;
    }
    await ref
        .read(habitActionsProvider.notifier)
        .checkIn(
          habitId: entry.habitId,
          onDate: _onDate,
          kind: ObservationInputKind.value,
          rawValue: amount,
          rawUnit: entry.targetKindWire == kHabitTargetDuration
              ? entry.displayUnit
              : entry.unit,
        );
  }

  String _unit(AppLocalizations l10n) => switch (entry.targetKindWire) {
    kHabitTargetDuration => entry.displayUnit ?? '',
    kHabitTargetQuantity => entry.unit ?? '',
    _ => '',
  };
}

/// A minimal amount-entry dialog for numeric check-ins. It owns its controller
/// so the field is disposed only after the dialog route is gone.
final class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.title, required this.unit});

  final String title;
  final String unit;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.habitAddEntryTo(widget.title)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: widget.unit.isEmpty
              ? l10n.habitAmountLabel
              : '${l10n.habitAmountLabel} (${widget.unit})',
        ),
        onSubmitted: (String value) => _submit(context, value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => _submit(context, _controller.text),
          child: Text(l10n.habitAddEntry),
        ),
      ],
    );
  }

  void _submit(BuildContext context, String raw) {
    final num? value = num.tryParse(raw.trim());
    Navigator.of(context).pop(value != null && value > 0 ? value : null);
  }
}
