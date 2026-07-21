import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';

/// The study-side duration contract consumed by combined focus/study metrics
/// (R-FOCUS-005, R-INSIGHT-001).
///
/// Focus and study durations SHALL NOT be summed as independent time; instead
/// their intervals are unioned. This application-boundary contract lets the
/// insights feature (task 7.4) obtain the current study spans in a range and
/// merge them with focus spans through the canonical [IntervalUnion], so
/// overlapping focus and study time is counted once. Consumers depend only on
/// this exported contract and the shared [TimeSpan], never on the learning
/// feature's infrastructure or domain (design.md §4/§16).
abstract interface class StudyDurationContract {
  /// The current (non-superseded) study-session spans that overlap
  /// `[rangeStartUtc, rangeEndUtc)`, optionally scoped to a Life Area or a
  /// single resource. Spans are clipped to the requested range so callers can
  /// union them with focus spans over the same window.
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  });
}
