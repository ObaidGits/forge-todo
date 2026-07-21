/// Canonical half-open `[startUtc, endUtc)` time interval and the single
/// interval-union algorithm shared across features.
///
/// A [TimeSpan] carries two instants in a caller-consistent unit (UTC
/// microseconds on the focus/study/insights path). It is the shared vocabulary
/// that lets one feature hand its intervals to another through an exported
/// application contract without leaking that feature's domain types
/// (design.md §4). Focus and learning both express their durations as
/// [TimeSpan]s so combined metrics can union them once.
///
/// [IntervalUnion] is the *one* interval-union implementation in the codebase.
/// It merges overlapping and touching spans so shared time is counted exactly
/// once and never summed as independent time (R-FOCUS-005, R-INSIGHT-001).
/// Feature policies delegate to it rather than re-deriving the math.
library;

/// A half-open `[startUtc, endUtc)` interval in a caller-consistent unit.
final class TimeSpan {
  TimeSpan({required this.startUtc, required this.endUtc}) {
    if (endUtc < startUtc) {
      throw FormatException(
        'Interval end ($endUtc) precedes start ($startUtc).',
      );
    }
  }

  final int startUtc;
  final int endUtc;

  /// The length of the span; never negative and zero for a point interval.
  int get lengthMicros => endUtc - startUtc;

  @override
  bool operator ==(Object other) =>
      other is TimeSpan && other.startUtc == startUtc && other.endUtc == endUtc;

  @override
  int get hashCode => Object.hash(startUtc, endUtc);

  @override
  String toString() => '[$startUtc, $endUtc)';
}

/// The one canonical interval-union policy (R-FOCUS-005, R-INSIGHT-001).
abstract final class IntervalUnion {
  static const int microsPerSecond = 1000000;

  /// The total length covered by [spans], merging overlapping *and* touching
  /// spans so shared time is counted exactly once. Zero-length spans contribute
  /// nothing. The result is deterministic and independent of input order.
  static int unionMicros(Iterable<TimeSpan> spans) {
    final List<TimeSpan> sorted =
        spans.where((TimeSpan s) => s.lengthMicros > 0).toList(growable: false)
          ..sort((TimeSpan a, TimeSpan b) {
            final int byStart = a.startUtc.compareTo(b.startUtc);
            return byStart != 0 ? byStart : a.endUtc.compareTo(b.endUtc);
          });
    if (sorted.isEmpty) {
      return 0;
    }
    int total = 0;
    int mergeStart = sorted.first.startUtc;
    int mergeEnd = sorted.first.endUtc;
    for (final TimeSpan span in sorted.skip(1)) {
      if (span.startUtc <= mergeEnd) {
        if (span.endUtc > mergeEnd) {
          mergeEnd = span.endUtc;
        }
      } else {
        total += mergeEnd - mergeStart;
        mergeStart = span.startUtc;
        mergeEnd = span.endUtc;
      }
    }
    return total + (mergeEnd - mergeStart);
  }

  /// The union length in whole seconds (truncated).
  static int unionSeconds(Iterable<TimeSpan> spans) =>
      unionMicros(spans) ~/ microsPerSecond;
}
