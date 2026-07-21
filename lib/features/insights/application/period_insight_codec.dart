import 'dart:convert';

import 'package:forge/features/insights/domain/metric_policy.dart';

/// The factual-close–derived, watermarked portion of a weekly/monthly Insight
/// that is cached durably and reproduced from source (R-INSIGHT-004).
///
/// Only the close-derived metrics are cached: they are the values sealed under
/// a `metric_policy_version` at a `source_commit_seq`, so caching them keyed by
/// that watermark makes recompute deterministic. The interval-unioned
/// focus/study time is *not* cached; it is recomputed live from source spans on
/// every read so it can never be served stale.
final class CachedPeriodMetrics {
  const CachedPeriodMetrics({
    required this.taskCompletion,
    required this.missedCount,
    required this.carriedCount,
    required this.habitConsistency,
    required this.metricPolicyNumber,
    required this.sourceWatermarkCommitSeq,
    required this.closedDayCount,
  });

  final MetricRatio taskCompletion;
  final int missedCount;
  final int carriedCount;
  final MetricRatio habitConsistency;
  final int metricPolicyNumber;
  final int sourceWatermarkCommitSeq;
  final int closedDayCount;
}

/// Deterministic JSON serialization for [CachedPeriodMetrics].
///
/// The encoding is stable and order-independent so the same metrics always
/// serialize to the same bytes, which keeps cache reproduction exact.
abstract final class PeriodInsightCodec {
  static String encode(CachedPeriodMetrics metrics) =>
      jsonEncode(<String, Object>{
        'v': 1,
        'task_num': metrics.taskCompletion.numerator,
        'task_den': metrics.taskCompletion.denominator,
        'missed': metrics.missedCount,
        'carried': metrics.carriedCount,
        'habit_num': metrics.habitConsistency.numerator,
        'habit_den': metrics.habitConsistency.denominator,
        'policy': metrics.metricPolicyNumber,
        'watermark': metrics.sourceWatermarkCommitSeq,
        'closed_days': metrics.closedDayCount,
      });

  static CachedPeriodMetrics decode(String json) {
    final Object? raw = jsonDecode(json);
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Malformed cached period metrics.');
    }
    return CachedPeriodMetrics(
      taskCompletion: MetricRatio(
        numerator: raw['task_num']! as int,
        denominator: raw['task_den']! as int,
      ),
      missedCount: raw['missed']! as int,
      carriedCount: raw['carried']! as int,
      habitConsistency: MetricRatio(
        numerator: raw['habit_num']! as int,
        denominator: raw['habit_den']! as int,
      ),
      metricPolicyNumber: raw['policy']! as int,
      sourceWatermarkCommitSeq: raw['watermark']! as int,
      closedDayCount: raw['closed_days']! as int,
    );
  }
}
