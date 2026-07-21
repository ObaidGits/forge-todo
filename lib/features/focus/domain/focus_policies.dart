import 'package:forge/core/domain/time_span.dart';

/// A half-open `[startUtc, endUtc)` interval in UTC microseconds.
///
/// Used to union focus work intervals for combined metrics so overlapping time
/// is counted once and never summed as independent time (R-FOCUS-005). It maps
/// to the canonical [TimeSpan] so the shared [IntervalUnion] does the math.
final class FocusTimeSpan {
  FocusTimeSpan({required this.startUtc, required this.endUtc})
    : assert(endUtc >= startUtc, 'end must not precede start') {
    if (endUtc < startUtc) {
      throw FormatException(
        'Interval end ($endUtc) precedes start ($startUtc).',
      );
    }
  }

  final int startUtc;
  final int endUtc;

  int get lengthMicros => endUtc - startUtc;

  /// This span as a canonical [TimeSpan] for the shared [IntervalUnion].
  TimeSpan toTimeSpan() => TimeSpan(startUtc: startUtc, endUtc: endUtc);

  @override
  bool operator ==(Object other) =>
      other is FocusTimeSpan &&
      other.startUtc == startUtc &&
      other.endUtc == endUtc;

  @override
  int get hashCode => Object.hash(startUtc, endUtc);

  @override
  String toString() => '[$startUtc, $endUtc)';
}

/// Pure interval math for focus/study combined metrics (R-FOCUS-005).
abstract final class FocusPolicies {
  static const int microsPerSecond = IntervalUnion.microsPerSecond;

  /// The total duration in microseconds covered by [spans], unioning any
  /// overlapping or touching spans so shared time is counted exactly once.
  ///
  /// This is the operation that guarantees focus and linked study durations are
  /// "not summed as independent time; overlap is unioned by interval"
  /// (R-FOCUS-005). It delegates to the canonical [IntervalUnion] so there is a
  /// single union implementation shared with combined focus/study metrics.
  static int unionDurationMicros(Iterable<FocusTimeSpan> spans) =>
      IntervalUnion.unionMicros(spans.map((FocusTimeSpan s) => s.toTimeSpan()));

  /// The union duration in whole seconds (truncated).
  static int unionDurationSec(Iterable<FocusTimeSpan> spans) =>
      unionDurationMicros(spans) ~/ microsPerSecond;

  /// Whether any two spans in [spans] overlap (share more than a touching
  /// boundary). Used to enforce the no-overlap invariant (R-FOCUS-003).
  static bool hasOverlap(Iterable<FocusTimeSpan> spans) {
    final List<FocusTimeSpan> sorted = spans.toList(growable: false)
      ..sort(
        (FocusTimeSpan a, FocusTimeSpan b) => a.startUtc.compareTo(b.startUtc),
      );
    for (int i = 1; i < sorted.length; i += 1) {
      if (sorted[i].startUtc < sorted[i - 1].endUtc) {
        return true;
      }
    }
    return false;
  }
}
