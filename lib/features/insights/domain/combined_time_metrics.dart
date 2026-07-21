/// Combined focus + study time over a transparent range, computed so that
/// overlapping focus and study time is counted exactly once (R-INSIGHT-001,
/// R-FOCUS-005, R-LEARN-002).
///
/// Focus and linked study durations SHALL NOT be summed as independent time;
/// their intervals are unioned. [combinedSeconds] is therefore the union of all
/// focus work spans and study spans in the range, which is always less than or
/// equal to `focusSeconds + studySeconds`. [overlapSeconds] is the shared time
/// removed by that union (`focus + study - combined`, computed in microseconds
/// so it is exact and never negative). The range and any filter are reported
/// alongside the values so the number is never an opaque score.
final class CombinedTimeMetrics {
  CombinedTimeMetrics({
    required this.rangeStartUtc,
    required this.rangeEndUtc,
    required this.focusSeconds,
    required this.studySeconds,
    required this.combinedSeconds,
    required this.overlapSeconds,
    this.lifeAreaId,
  }) {
    if (rangeEndUtc < rangeStartUtc) {
      throw FormatException(
        'Range end ($rangeEndUtc) precedes start ($rangeStartUtc).',
      );
    }
    if (focusSeconds < 0 ||
        studySeconds < 0 ||
        combinedSeconds < 0 ||
        overlapSeconds < 0) {
      throw FormatException('Combined-time seconds must be nonnegative.');
    }
  }

  final int rangeStartUtc;
  final int rangeEndUtc;

  /// Interval-union of focus work time in seconds.
  final int focusSeconds;

  /// Interval-union of study time in seconds.
  final int studySeconds;

  /// Interval-union of focus work spans and study spans together in seconds:
  /// overlapping focus/study time is counted once (R-INSIGHT-001).
  final int combinedSeconds;

  /// The time shared by focus and study that the union removed, in seconds.
  final int overlapSeconds;

  /// The applied Life Area filter, when scoped.
  final String? lifeAreaId;
}
