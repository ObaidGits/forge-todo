import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Opens the backfill / correction impact-preview interface for [dateIso]
/// (R-HABIT-005).
///
/// The sheet lets the user choose the outcome to preview and shows the exact
/// streak and consistency both before and after the change under metric policy
/// v1 — nothing is committed until the user applies it. Copy is neutral: it
/// describes the projected effect factually and never frames a miss as a
/// personal failure (R-HABIT-006).
Future<void> showHabitImpactPreview(
  BuildContext context, {
  required String habitId,
  required String targetKindWire,
  required String dateIso,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext context) => _HabitImpactPreviewSheet(
      habitId: habitId,
      targetKindWire: targetKindWire,
      dateIso: dateIso,
    ),
  );
}

final class _HabitImpactPreviewSheet extends ConsumerStatefulWidget {
  const _HabitImpactPreviewSheet({
    required this.habitId,
    required this.targetKindWire,
    required this.dateIso,
  });

  final String habitId;
  final String targetKindWire;
  final String dateIso;

  @override
  ConsumerState<_HabitImpactPreviewSheet> createState() =>
      _HabitImpactPreviewSheetState();
}

class _HabitImpactPreviewSheetState
    extends ConsumerState<_HabitImpactPreviewSheet> {
  HabitPreviewOutcome _outcome = HabitPreviewOutcome.completed;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AsyncValue<HabitImpactPreview?> preview = ref.watch(
      habitImpactPreviewProvider((
        habitId: widget.habitId,
        onDateIso: widget.dateIso,
        outcome: _outcome,
      )),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ForgeSpacing.lg,
          0,
          ForgeSpacing.lg,
          ForgeSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                l10n.habitBackfillDay(widget.dateIso),
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: ForgeSpacing.xs),
            Text(l10n.habitBackfillExplain, style: theme.textTheme.bodyMedium),
            const SizedBox(height: ForgeSpacing.md),
            Text(
              l10n.habitBackfillOutcomeLabel,
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: ForgeSpacing.xs),
            _OutcomeChoices(
              selected: _outcome,
              onSelected: (HabitPreviewOutcome value) =>
                  setState(() => _outcome = value),
            ),
            const SizedBox(height: ForgeSpacing.md),
            preview.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: ForgeSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (Object error, _) => Text(l10n.errorUnexpected),
              data: (HabitImpactPreview? value) => value == null
                  ? const SizedBox.shrink()
                  : _preview(l10n, value),
            ),
            const SizedBox(height: ForgeSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: _applyButton(context, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(AppLocalizations l10n, HabitImpactPreview value) {
    final ThemeData theme = Theme.of(context);
    final String consistencyBefore = HabitLabels.consistency(
      l10n,
      value.consistencyBefore,
    );
    final String consistencyAfter = HabitLabels.consistency(
      l10n,
      value.consistencyAfter,
    );
    final bool noChange =
        value.streakBefore == value.streakAfter &&
        consistencyBefore == consistencyAfter;
    return Container(
      key: const ValueKey<String>('habit-impact-preview'),
      width: double.infinity,
      padding: const EdgeInsets.all(ForgeSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ForgeRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.habitBackfillStreak(value.streakBefore, value.streakAfter),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: ForgeSpacing.xxs),
          Text(
            l10n.habitBackfillConsistency(consistencyBefore, consistencyAfter),
            style: theme.textTheme.bodyMedium,
          ),
          if (noChange) ...<Widget>[
            const SizedBox(height: ForgeSpacing.xxs),
            Text(
              l10n.habitBackfillNoChange,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: ForgeSpacing.xxs),
          Text(
            HabitLabels.metricPolicy(l10n, value.metricPolicyVersion),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Apply is offered only for outcomes that map to a single, unambiguous
  /// command for this habit's target kind. A skip applies to any kind; marking
  /// a boolean habit done backfills a true check-in. Other combinations remain
  /// preview-only so the interface never guesses a numeric amount.
  Widget? _applyButtonChild(AppLocalizations l10n) {
    final bool canApply =
        _outcome == HabitPreviewOutcome.skipped ||
        (_outcome == HabitPreviewOutcome.completed &&
            widget.targetKindWire == kHabitTargetBoolean);
    if (!canApply) {
      return null;
    }
    return FilledButton(
      onPressed: () => unawaited(_apply(context)),
      child: Text(l10n.habitBackfillApply),
    );
  }

  Widget _applyButton(BuildContext context, AppLocalizations l10n) {
    return _applyButtonChild(l10n) ?? const SizedBox.shrink();
  }

  Future<void> _apply(BuildContext context) async {
    final LocalDate onDate = LocalDate.parse(widget.dateIso);
    final HabitActionsController actions = ref.read(
      habitActionsProvider.notifier,
    );
    bool ok = false;
    if (_outcome == HabitPreviewOutcome.skipped) {
      ok = await actions.skip(habitId: widget.habitId, onDate: onDate);
    } else if (_outcome == HabitPreviewOutcome.completed &&
        widget.targetKindWire == kHabitTargetBoolean) {
      ok = await actions.checkIn(
        habitId: widget.habitId,
        onDate: onDate,
        kind: ObservationInputKind.booleanTrue,
      );
    }
    if (ok && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _OutcomeChoices extends StatelessWidget {
  const _OutcomeChoices({required this.selected, required this.onSelected});

  final HabitPreviewOutcome selected;
  final void Function(HabitPreviewOutcome) onSelected;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Wrap(
      spacing: ForgeSpacing.xs,
      children: <Widget>[
        for (final HabitPreviewOutcome outcome in HabitPreviewOutcome.values)
          ChoiceChip(
            label: Text(HabitLabels.previewOutcome(l10n, outcome)),
            selected: selected == outcome,
            onSelected: (_) => onSelected(outcome),
          ),
      ],
    );
  }
}
