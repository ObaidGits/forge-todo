/// Transparent learning statistics over a date range (R-LEARN-005).
///
/// Studied duration is the interval-union of current study sessions overlapping
/// the range, so overlapping/concurrent sessions are counted once and can be
/// combined with focus time without double counting (R-FOCUS-005). Completed
/// items counts eligible items whose completion instant falls in the range. The
/// range and filters are reported alongside the values so the numbers are never
/// an opaque score.
final class LearningStatistics {
  const LearningStatistics({
    required this.rangeStartUtc,
    required this.rangeEndUtc,
    required this.studiedDurationSec,
    required this.completedItems,
    required this.sessionCount,
    this.lifeAreaId,
    this.resourceId,
  });

  final int rangeStartUtc;
  final int rangeEndUtc;

  /// Interval-union of studied time in seconds (R-FOCUS-005).
  final int studiedDurationSec;

  /// Eligible items completed within the range.
  final int completedItems;

  /// Number of current study sessions that overlapped the range.
  final int sessionCount;

  /// The applied Life Area filter, when scoped.
  final String? lifeAreaId;

  /// The applied resource filter, when scoped.
  final String? resourceId;
}
