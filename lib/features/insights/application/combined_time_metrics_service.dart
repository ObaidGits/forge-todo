import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';

/// Computes combined focus + study time metrics without double-counting
/// overlapping intervals (R-INSIGHT-001, R-FOCUS-005, R-LEARN-002).
///
/// This is the small cross-feature integration for task 7.4. It composes the
/// exported [FocusDurationContract] and [StudyDurationContract] — never the
/// focus or learning infrastructure/domain (design.md §4) — and merges their
/// spans through the one canonical [IntervalUnion]. A study session may be
/// linked to a focus session, so their intervals routinely overlap; unioning
/// the two span sets guarantees that shared time is counted exactly once
/// instead of being summed as independent time.
final class CombinedTimeMetricsService {
  const CombinedTimeMetricsService({
    required this.focusDuration,
    required this.studyDuration,
  });

  final FocusDurationContract focusDuration;
  final StudyDurationContract studyDuration;

  /// The combined focus + study time over `[rangeStartUtc, rangeEndUtc)`,
  /// optionally scoped to a Life Area. Focus work spans and study spans are
  /// unioned together so overlapping focus/study time is counted once.
  Future<CombinedTimeMetrics> combinedTime(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async {
    if (rangeEndUtc < rangeStartUtc) {
      throw FormatException(
        'Range end ($rangeEndUtc) precedes start ($rangeStartUtc).',
      );
    }
    final List<TimeSpan> focusSpans = await focusDuration.focusWorkSpans(
      profileId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      lifeAreaId: lifeAreaId,
    );
    final List<TimeSpan> studySpans = await studyDuration.studyIntervals(
      profileId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      lifeAreaId: lifeAreaId,
    );

    // Union each source independently, then union them together. Computing the
    // overlap in microseconds keeps it exact and never negative even when the
    // per-source second totals are individually truncated.
    final int focusMicros = IntervalUnion.unionMicros(focusSpans);
    final int studyMicros = IntervalUnion.unionMicros(studySpans);
    final int combinedMicros = IntervalUnion.unionMicros(<TimeSpan>[
      ...focusSpans,
      ...studySpans,
    ]);
    final int overlapMicros = focusMicros + studyMicros - combinedMicros;

    return CombinedTimeMetrics(
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      focusSeconds: focusMicros ~/ IntervalUnion.microsPerSecond,
      studySeconds: studyMicros ~/ IntervalUnion.microsPerSecond,
      combinedSeconds: combinedMicros ~/ IntervalUnion.microsPerSecond,
      overlapSeconds: overlapMicros ~/ IntervalUnion.microsPerSecond,
      lifeAreaId: lifeAreaId?.value,
    );
  }
}
