/// Metric policy v1: the single authoritative, versioned interpretation of the
/// MVP metrics composed into the Daily Summary (R-HOME-004, R-PLAN-003,
/// R-HABIT-007, R-INSIGHT-004).
///
/// Metric policy v1 is not a second implementation of the underlying rules; it
/// is the umbrella that names the version and composes the already-authoritative
/// pieces:
///
/// * task completion is the eligible/completed set captured by the planner's
///   immutable factual close (set-union of planned and due, deduplicated,
///   as-of-close);
/// * focus + study time is unioned by the one canonical interval-union
///   (`IntervalUnion`) so overlapping time is counted once;
/// * habit outcomes are the as-of-close occurrence statuses, tallied with the
///   same treatment habit metric policy v1 uses (paused excluded from the
///   denominator, a skip kept in the denominator but never the numerator,
///   R-HABIT-007).
///
/// The single displayed version tag ([version]) matches the habits feature's
/// `kHabitMetricPolicyVersion`, so every surface that shows a metric-policy-v1
/// number displays the same label. Any future treatment change requires a new
/// displayed policy version and must never rewrite a prior factual close
/// (R-HABIT-007, R-PLAN-003); this module is therefore pure and stable.
library;

/// The stable version tag displayed alongside every metric-policy-v1 value.
///
/// It is identical to the habits feature's tag so the composed Daily Summary
/// and the standalone habit statistics never disagree about which policy
/// produced a number.
const String kMetricPolicyVersion = 'metric-policy-v1';

/// The numeric metric-policy version persisted on an immutable factual close
/// (`planning_close_events.metric_policy_version`). The factual close snapshot
/// is policy-independent; this records which policy was in effect at close.
const int kMetricPolicyNumber = 1;

/// A metric expressed as a transparent numerator over denominator
/// (R-HOME-004, R-INSIGHT-002).
///
/// [ratio] is null exactly when [denominator] is zero, which every surface must
/// render as "no data" rather than a misleading 0% (R-INSIGHT-002). Both counts
/// are nonnegative and the numerator never exceeds the denominator.
final class MetricRatio {
  MetricRatio({required this.numerator, required this.denominator}) {
    if (numerator < 0 || denominator < 0) {
      throw FormatException(
        'Metric counts must be nonnegative (got $numerator/$denominator).',
      );
    }
    if (numerator > denominator) {
      throw FormatException(
        'Metric numerator ($numerator) exceeds denominator ($denominator).',
      );
    }
  }

  /// A metric with no eligible data.
  const MetricRatio.empty() : numerator = 0, denominator = 0;

  final int numerator;
  final int denominator;

  /// The completion fraction in `0..1`, or null when there is no eligible data.
  double? get ratio => denominator == 0 ? null : numerator / denominator;

  /// Whether there is any eligible data; a false value means "no data", not 0%.
  bool get hasData => denominator > 0;

  @override
  bool operator ==(Object other) =>
      other is MetricRatio &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => 'MetricRatio($numerator/$denominator)';
}

/// The pure metric-policy-v1 interpretation functions (R-HOME-004,
/// R-HABIT-007).
abstract final class MetricPolicyV1 {
  /// The displayed policy version tag.
  static const String version = kMetricPolicyVersion;

  /// The numeric policy version recorded at factual close.
  static const int number = kMetricPolicyNumber;

  /// The displayed label for a numeric policy version stored on a factual
  /// close, e.g. `1` renders as `metric-policy-v1`. A newer policy renders its
  /// own label so a recomputed summary never masquerades as v1 (R-PLAN-003).
  static String label(int numericVersion) {
    if (numericVersion < 1) {
      throw FormatException('Metric policy version must be >= 1.');
    }
    return 'metric-policy-v$numericVersion';
  }

  /// Task completion under metric policy v1: completed eligible tasks over the
  /// eligible set. The eligible set is the deduplicated set-union of planned and
  /// due tasks captured as-of-close, so a task that is both planned and due is
  /// counted exactly once (R-HOME-004). This reads the sealed close counts; it
  /// never recomputes them from mutable current state, so the value reflects the
  /// factual close and not later corrections (R-PLAN-003).
  static MetricRatio taskCompletion({
    required int eligible,
    required int completed,
  }) => MetricRatio(numerator: completed, denominator: eligible);
}
