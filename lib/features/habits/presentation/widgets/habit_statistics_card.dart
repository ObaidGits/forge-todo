import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A transparent streak + consistency card under metric policy v1 (R-HABIT-004,
/// R-HABIT-007).
///
/// It always shows the displayed metric-policy version and, for consistency,
/// the exact numerator/denominator. When there is no eligible data the card
/// shows the neutral "no eligible data" state rather than a misleading 0%
/// (R-HABIT-007). Values are exposed as text, never color alone (ux-design §5).
final class HabitStatisticsCard extends StatelessWidget {
  const HabitStatisticsCard({required this.statistics, super.key});

  final HabitStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);

    return Card(
      key: const ValueKey<String>('habit-statistics-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!statistics.hasData)
              Text(l10n.habitStatsNoData, style: theme.textTheme.bodyMedium)
            else ...<Widget>[
              _Metric(
                label: l10n.habitStatsStreakLabel,
                value: l10n.habitStatsStreakValue(statistics.currentStreak),
              ),
              const SizedBox(height: ForgeSpacing.sm),
              _Metric(
                label: l10n.habitStatsConsistencyLabel,
                value: HabitLabels.consistency(l10n, statistics.consistency),
              ),
            ],
            const SizedBox(height: ForgeSpacing.md),
            Text(
              l10n.habitStatsRange(statistics.fromIso, statistics.toIso),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ForgeSpacing.xxs),
            Text(
              HabitLabels.metricPolicy(l10n, statistics.metricPolicyVersion),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 140,
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Text(value, style: theme.textTheme.titleMedium)),
          ],
        ),
      ),
    );
  }
}
