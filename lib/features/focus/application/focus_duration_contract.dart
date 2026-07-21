import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';

/// The focus-side duration contract consumed by combined focus/study metrics
/// (R-FOCUS-005, R-INSIGHT-001).
///
/// Focus and study durations SHALL NOT be summed as independent time; instead
/// their intervals are unioned. This application-boundary contract lets the
/// insights feature (task 7.4) obtain the closed focus *work* spans in a range
/// and merge them with study spans through the canonical [IntervalUnion], so
/// overlapping focus and study time is counted once. Consumers depend only on
/// this exported contract and the shared [TimeSpan], never on the focus
/// feature's infrastructure or domain (design.md §4/§16).
abstract interface class FocusDurationContract {
  /// The closed focus *work* spans that overlap `[rangeStartUtc, rangeEndUtc)`,
  /// optionally scoped to a Life Area. Pause intervals and still-open intervals
  /// are excluded, and each span is clipped to the requested range so callers
  /// can union it with study spans over the same window (R-FOCUS-005).
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  });
}
