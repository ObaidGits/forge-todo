import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/insights/presentation/insight_labels.dart';

/// The accessible data-table alternative for a weekly/monthly Insight chart
/// (R-INSIGHT-003, R-INSIGHT-005, NFR-A11Y).
///
/// Every chart in Insights has this semantic table alternative: it renders each
/// explainable metric as a text row (value with its numerator/denominator or
/// underlying seconds, plus the period-over-period trend), never relying on
/// color to convey meaning. A zero-denominator metric shows "no data", not a
/// misleading 0% (R-INSIGHT-002), and an absent trend shows "no comparison"
/// rather than a fabricated delta. The caption states the date range, timezone,
/// filter, and formula version, and the notes state the paused/skipped
/// treatment and the missing-data caveat (R-INSIGHT-002).
final class InsightDataTable extends StatelessWidget {
  const InsightDataTable({
    required this.comparison,
    this.labels = InsightLabels.en,
    super.key,
  });

  final PeriodInsightComparison comparison;
  final InsightLabels labels;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PeriodInsight insight = comparison.current;
    final List<InsightRow> rows = InsightFormat.rows(comparison, labels);
    final TextStyle? captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      key: const ValueKey<String>('insight-data-table'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                labels.titleFor(insight.period.kind),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: ForgeSpacing.xs),
            Text(InsightFormat.caption(insight), style: captionStyle),
            const SizedBox(height: ForgeSpacing.sm),
            // A DataTable is an explicit, screen-reader-navigable table
            // alternative to any chart of the same figures.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                key: const ValueKey<String>('insight-table'),
                columns: <DataColumn>[
                  DataColumn(label: Text(labels.metricColumn)),
                  DataColumn(label: Text(labels.valueColumn)),
                  DataColumn(label: Text(labels.trendColumn)),
                ],
                rows: <DataRow>[
                  for (final InsightRow row in rows)
                    DataRow(
                      cells: <DataCell>[
                        DataCell(Text(row.label)),
                        DataCell(Text(row.value)),
                        DataCell(Text(row.trend)),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: ForgeSpacing.sm),
            Text(labels.pausedSkippedNote, style: captionStyle),
            const SizedBox(height: ForgeSpacing.xxs),
            Text(labels.missingDataCaveat, style: captionStyle),
          ],
        ),
      ),
    );
  }
}

/// A compact accessible summary that pairs with a chart, exposing the same
/// figures as a single semantic reading for assistive technology
/// (R-INSIGHT-003).
final class InsightChartSemantics extends StatelessWidget {
  const InsightChartSemantics({
    required this.comparison,
    required this.child,
    this.labels = InsightLabels.en,
    super.key,
  });

  final PeriodInsightComparison comparison;
  final InsightLabels labels;

  /// The visual chart the semantics describe.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final List<InsightRow> rows = InsightFormat.rows(comparison, labels);
    final String reading = <String>[
      labels.titleFor(comparison.current.period.kind),
      InsightFormat.caption(comparison.current),
      for (final InsightRow row in rows) row.semanticLabel,
    ].join('. ');

    // The chart itself is decorative for assistive technology; the semantic
    // reading carries the same data as the table alternative.
    return Semantics(
      container: true,
      label: reading,
      child: ExcludeSemantics(child: child),
    );
  }
}
