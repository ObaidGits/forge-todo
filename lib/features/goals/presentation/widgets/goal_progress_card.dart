import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/presentation/goal_labels.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The transparent progress surface for a goal or roadmap (R-GOAL-004).
///
/// It always shows how the value was derived: the human-readable formula, the
/// eligible leaf count, and the total (and completed) weight. When no progress
/// is computable it says "not started / no computable progress" rather than a
/// misleading 0%. The bar is decorative; the value and derivation are text so
/// color is never the sole signal (ux-design §5, §11).
final class GoalProgressCard extends StatelessWidget {
  const GoalProgressCard({required this.progress, super.key});

  final GoalProgress progress;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String valueText = GoalLabels.progressValue(l10n, progress);
    final String modeText = GoalLabels.progressMode(l10n, progress.mode);

    return Semantics(
      container: true,
      label: l10n.goalProgressSemantics(valueText, modeText),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(ForgeSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.goalProgressHeading,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(modeText, style: theme.textTheme.labelMedium),
                ],
              ),
              const SizedBox(height: ForgeSpacing.xs),
              ExcludeSemantics(
                child: LinearProgressIndicator(
                  value: progress.value ?? 0,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Text(valueText, style: theme.textTheme.bodyLarge),
              const SizedBox(height: ForgeSpacing.xs),
              // The transparent derivation (R-GOAL-004): formula + eligible
              // count + total weight, always visible.
              Text(
                l10n.goalProgressFormulaLabel(progress.formula),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                l10n.goalProgressLeafCount(progress.eligibleCount),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                l10n.goalProgressWeights(
                  _fmt(progress.completedWeight),
                  _fmt(progress.totalWeight),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(num value) {
    if (value is int || value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }
}

/// A compact, presentation-only per-section aggregation label (R-GOAL-004).
/// Sections carry no completion weight of their own; this simply reports the
/// aggregation of eligible descendant topic weights using the identical
/// formula, so it can never diverge from or double-count against the total.
final class SectionAggregationChip extends StatelessWidget {
  const SectionAggregationChip({required this.aggregation, super.key});

  final GoalProgress aggregation;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String valueText = GoalLabels.progressValue(l10n, aggregation);
    return Tooltip(
      message: l10n.goalSectionAggregationTooltip(aggregation.eligibleCount),
      child: Chip(
        label: Text(valueText),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
