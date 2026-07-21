import 'package:forge/core/domain/local_date_time.dart';

/// How a wall-clock time that is ambiguous or nonexistent under DST is resolved
/// to a single absolute instant (R-GEN-004 "defined DST behavior").
///
/// * A spring-forward gap (e.g. 02:30 on a day the clock jumps 02:00→03:00)
///   names a wall-clock time that never occurs.
/// * A fall-back overlap (e.g. 01:30 on a day the clock repeats 02:00→01:00)
///   names a wall-clock time that occurs twice.
///
/// Forge fixes deterministic policies so the same schedule always produces the
/// same instant on every device and run:
enum DstPolicy {
  /// Gap: take the instant after the transition (shift the wall time forward
  /// by the gap). Overlap: take the earlier (first, pre-transition) instant.
  ///
  /// This is the default and matches common calendar behavior: a reminder set
  /// for a skipped local time fires at the moment the clock jumps, and a
  /// repeated local time fires the first time it is reached.
  forwardGapEarlierOverlap,

  /// Gap: take the instant before the transition. Overlap: take the later
  /// (second, post-transition) instant.
  backwardGapLaterOverlap,
}

/// A resolved conversion of a wall-clock time to an absolute instant, carrying
/// enough context to explain DST handling deterministically.
final class ZonedInstant {
  const ZonedInstant({
    required this.utcMicros,
    required this.timezoneId,
    required this.offsetSeconds,
    this.wasGap = false,
    this.wasOverlap = false,
  });

  /// The absolute instant in UTC microseconds since the Unix epoch.
  final int utcMicros;

  /// The IANA timezone the wall-clock time was interpreted in.
  final String timezoneId;

  /// The UTC offset, in seconds, in effect at [utcMicros].
  final int offsetSeconds;

  /// The requested wall-clock time fell in a spring-forward gap.
  final bool wasGap;

  /// The requested wall-clock time fell in a fall-back overlap.
  final bool wasOverlap;

  @override
  bool operator ==(Object other) =>
      other is ZonedInstant &&
      other.utcMicros == utcMicros &&
      other.timezoneId == timezoneId &&
      other.offsetSeconds == offsetSeconds &&
      other.wasGap == wasGap &&
      other.wasOverlap == wasOverlap;

  @override
  int get hashCode =>
      Object.hash(utcMicros, timezoneId, offsetSeconds, wasGap, wasOverlap);
}

/// Thrown when an IANA timezone id is unknown to the resolver.
final class UnknownTimeZoneError implements Exception {
  const UnknownTimeZoneError(this.timezoneId);
  final String timezoneId;

  @override
  String toString() => 'Unknown IANA timezone: $timezoneId';
}

/// Pure port that converts between wall-clock local times and absolute UTC
/// instants for an IANA timezone with deterministic DST handling.
///
/// The interface is pure domain: it names no concrete timezone database. The
/// production adapter (built on the pinned `timezone` package) is assembled at
/// the composition root and injected into feature infrastructure, so domain
/// policies remain free of any plugin or database dependency.
abstract interface class TimeZoneResolver {
  /// Whether [timezoneId] is a recognized IANA zone.
  bool supportsZone(String timezoneId);

  /// Converts a wall-clock [local] time in [timezoneId] to an absolute instant,
  /// resolving DST gaps/overlaps by [policy].
  ///
  /// Throws [UnknownTimeZoneError] when [timezoneId] is not recognized.
  ZonedInstant toInstant(
    String timezoneId,
    LocalDateTime local, {
    DstPolicy policy = DstPolicy.forwardGapEarlierOverlap,
  });

  /// Converts an absolute [utcMicros] instant back to the wall-clock time
  /// observed in [timezoneId].
  ///
  /// Throws [UnknownTimeZoneError] when [timezoneId] is not recognized.
  LocalDateTime toLocal(String timezoneId, int utcMicros);
}
