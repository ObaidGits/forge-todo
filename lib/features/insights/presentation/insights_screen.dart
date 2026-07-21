import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/presentation/insight_data_table.dart';
import 'package:forge/features/insights/presentation/insights_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible weekly/monthly Insights screen (R-INSIGHT-001..005,
/// NFR-A11Y).
///
/// One calm screen renders the current weekly or monthly Insight for the active
/// profile as a chart with its always-present text/table alternative. Every
/// figure is explainable — task completion and habit consistency show their
/// numerator/denominator, combined focus/study time shows its underlying
/// seconds — and no opaque composite score is ever produced (R-INSIGHT-005). A
/// zero-denominator metric renders as "no data", never a misleading 0%
/// (R-INSIGHT-002). The caption states the date range, timezone, filter, and
/// formula version, and the notes state the paused/skipped treatment and the
/// missing-data caveat, all carried by the reused [InsightDataTable]. Nothing
/// is color-only, and the chart is described to assistive technology through
/// [InsightChartSemantics] (R-INSIGHT-003).
///
/// Insights has no navigation-rail tab; it is reached from the Settings hub.
final class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;

    if (!ref.watch(insightsConfiguredProvider)) {
      return ForgeEmptyState(
        icon: Icons.insights_outlined,
        title: l10n.insightsTitle,
        body: l10n.insightsUnavailable,
      );
    }

    final AsyncValue<PeriodInsightComparison?> comparison = ref.watch(
      insightComparisonProvider,
    );
    return comparison.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (PeriodInsightComparison? data) {
        if (data == null) {
          return ForgeEmptyState(
            icon: Icons.insights_outlined,
            title: l10n.insightsTitle,
            body: l10n.insightsUnavailable,
          );
        }
        return _InsightsView(comparison: data);
      },
    );
  }
}

final class _InsightsView extends ConsumerWidget {
  const _InsightsView({required this.comparison});

  final PeriodInsightComparison comparison;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InsightPeriodKind selected = ref.watch(insightPeriodProvider);

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-insights',
        padding: const EdgeInsets.symmetric(
          horizontal: ForgeSpacing.md,
          vertical: ForgeSpacing.sm,
        ),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _PeriodToggle(
                    selected: selected,
                    onSelected: (InsightPeriodKind kind) =>
                        ref.read(insightPeriodProvider.notifier).select(kind),
                  ),
                  const SizedBox(height: ForgeSpacing.md),
                  // The chart is decorative for assistive technology; its
                  // semantic reading and the table below carry the same data
                  // (R-INSIGHT-003).
                  InsightChartSemantics(
                    comparison: comparison,
                    child: _RatioBars(insight: comparison.current),
                  ),
                  const SizedBox(height: ForgeSpacing.md),
                  InsightDataTable(comparison: comparison),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The weekly/monthly toggle. A segmented control keeps both options visible
/// and keyboard-operable; the text labels carry the meaning, never colour alone
/// (NFR-A11Y-001, NFR-A11Y-003).
final class _PeriodToggle extends StatelessWidget {
  const _PeriodToggle({required this.selected, required this.onSelected});

  final InsightPeriodKind selected;
  final ValueChanged<InsightPeriodKind> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.insightsPeriodLabel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: ForgeSizes.minimumInteractiveDimension,
        ),
        child: SegmentedButton<InsightPeriodKind>(
          segments: <ButtonSegment<InsightPeriodKind>>[
            ButtonSegment<InsightPeriodKind>(
              value: InsightPeriodKind.weekly,
              label: Text(l10n.insightsWeekly),
              icon: const Icon(Icons.view_week_outlined),
            ),
            ButtonSegment<InsightPeriodKind>(
              value: InsightPeriodKind.monthly,
              label: Text(l10n.insightsMonthly),
              icon: const Icon(Icons.calendar_view_month_outlined),
            ),
          ],
          selected: <InsightPeriodKind>{selected},
          onSelectionChanged: (Set<InsightPeriodKind> selection) =>
              onSelected(selection.first),
        ),
      ),
    );
  }
}

/// A minimal decorative bar visual for the two ratio metrics. It is wrapped by
/// [InsightChartSemantics], which excludes it from assistive technology and
/// provides the equivalent text reading, so the bars never carry meaning by
/// colour or length alone. A no-data metric renders an empty track rather than
/// a misleading full/zero bar (R-INSIGHT-002, R-INSIGHT-003).
final class _RatioBars extends StatelessWidget {
  const _RatioBars({required this.insight});

  final PeriodInsight insight;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Bar(ratio: insight.taskCompletion),
            const SizedBox(height: ForgeSpacing.sm),
            _Bar(ratio: insight.habitConsistency),
          ],
        ),
      ),
    );
  }
}

final class _Bar extends StatelessWidget {
  const _Bar({required this.ratio});

  final MetricRatio ratio;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? value = ratio.ratio;
    return Container(
      height: ForgeSpacing.md,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ForgeSpacing.xs),
      ),
      alignment: Alignment.centerLeft,
      child: value == null
          ? const SizedBox.shrink()
          : FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(ForgeSpacing.xs),
                ),
                child: const SizedBox(height: ForgeSpacing.md),
              ),
            ),
    );
  }
}
