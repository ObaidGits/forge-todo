/// Deterministic timer-truth reconciliation for focus sessions (R-FOCUS-002).
///
/// A running focus session persists four facts about the *current* work
/// segment: a wall-clock anchor, a monotonic anchor, the boot/session id the
/// monotonic anchor was taken under, and the duration already accumulated from
/// previously-completed segments. The live elapsed time of a running session is
/// the accumulated duration plus the length of the current segment.
///
/// The length of the current segment is derived here, never stored as a ticking
/// value, so the timer stays correct across pause, process death, and clock
/// changes:
///
///  * **Same boot** — the monotonic clock is authoritative and immune to wall
///    changes, so the segment is the monotonic delta. This is what makes an
///    8-hour timer or a mid-session NTP correction exact.
///  * **Different boot (reboot / discontinuity)** — the monotonic anchor is
///    meaningless, so the segment falls back to a *bounded* wall-clock delta.
///    If the wall delta is negative (the clock moved backwards) or exceeds the
///    plausibility bound, the result is ambiguous and the caller must ask the
///    user for a correction rather than record a fabricated duration.
library;

/// The persisted timer truth of the current running segment (R-FOCUS-002).
final class TimerTruth {
  const TimerTruth({
    required this.bootSessionId,
    required this.monotonicAnchor,
    required this.wallAnchorUtcMicros,
  });

  /// Boot/session id the [monotonicAnchor] was captured under.
  final String bootSessionId;

  /// Monotonic elapsed-since-boot reading captured when the segment started.
  final Duration monotonicAnchor;

  /// Wall-clock instant (UTC microseconds) the segment started at.
  final int wallAnchorUtcMicros;
}

/// A live reading of both clocks taken now (R-FOCUS-002).
final class TimerReading {
  const TimerReading({
    required this.bootSessionId,
    required this.monotonic,
    required this.wallUtcMicros,
  });

  final String bootSessionId;
  final Duration monotonic;
  final int wallUtcMicros;
}

/// Which clock produced a resolved elapsed value.
enum ElapsedSource {
  /// The monotonic clock under a matching boot id (authoritative).
  monotonic,

  /// Bounded wall-clock reconciliation after a boot change.
  wallClock,
}

/// The outcome of reconciling timer truth against a live reading.
sealed class ElapsedResolution {
  const ElapsedResolution();
}

/// A confidently-resolved current-segment length.
final class ElapsedKnown extends ElapsedResolution {
  const ElapsedKnown({required this.segment, required this.source});

  /// The length of the current running segment.
  final Duration segment;

  /// Which clock produced [segment].
  final ElapsedSource source;

  @override
  bool operator ==(Object other) =>
      other is ElapsedKnown &&
      other.segment == segment &&
      other.source == source;

  @override
  int get hashCode => Object.hash(segment, source);
}

/// The segment length could not be resolved without user input (R-FOCUS-002).
///
/// A best-effort [lowerBound] (never negative) and the raw [wallEstimate] are
/// carried so the UI can pre-fill a correction prompt, but neither is recorded
/// as truth until the user confirms.
final class ElapsedAmbiguous extends ElapsedResolution {
  const ElapsedAmbiguous({
    required this.reason,
    required this.lowerBound,
    required this.wallEstimate,
  });

  final AmbiguityReason reason;
  final Duration lowerBound;
  final Duration wallEstimate;

  @override
  bool operator ==(Object other) =>
      other is ElapsedAmbiguous &&
      other.reason == reason &&
      other.lowerBound == lowerBound &&
      other.wallEstimate == wallEstimate;

  @override
  int get hashCode => Object.hash(reason, lowerBound, wallEstimate);
}

/// Why a wall-clock reconciliation was ambiguous.
enum AmbiguityReason {
  /// The wall clock moved backwards since the anchor.
  wallClockWentBackwards,

  /// The wall delta exceeded the plausibility bound for the session.
  wallDeltaExceedsBound,

  /// The monotonic clock moved backwards under a matching boot id (should be
  /// impossible; treated defensively as ambiguous rather than trusted).
  monotonicWentBackwards,
}

/// Pure timer-truth reconciliation (R-FOCUS-002).
abstract final class FocusTimePolicy {
  /// Resolves the length of the current running segment.
  ///
  /// When [maxPlausibleSegment] is provided, a wall-clock delta larger than it
  /// after a boot change is treated as ambiguous. It is ignored while the boot
  /// id matches because the monotonic clock is authoritative there.
  static ElapsedResolution resolveSegment(
    TimerTruth truth,
    TimerReading now, {
    Duration? maxPlausibleSegment,
  }) {
    if (truth.bootSessionId == now.bootSessionId) {
      final Duration segment = now.monotonic - truth.monotonicAnchor;
      if (segment.isNegative) {
        // A monotonic clock must never regress under one boot; refuse to
        // fabricate time and ask for a correction instead.
        final Duration wall = _wallDelta(truth, now);
        return ElapsedAmbiguous(
          reason: AmbiguityReason.monotonicWentBackwards,
          lowerBound: Duration.zero,
          wallEstimate: wall.isNegative ? Duration.zero : wall,
        );
      }
      return ElapsedKnown(segment: segment, source: ElapsedSource.monotonic);
    }

    // Boot changed: monotonic anchor is meaningless. Fall back to wall time.
    final Duration wall = _wallDelta(truth, now);
    if (wall.isNegative) {
      return const ElapsedAmbiguous(
        reason: AmbiguityReason.wallClockWentBackwards,
        lowerBound: Duration.zero,
        wallEstimate: Duration.zero,
      );
    }
    if (maxPlausibleSegment != null && wall > maxPlausibleSegment) {
      return ElapsedAmbiguous(
        reason: AmbiguityReason.wallDeltaExceedsBound,
        lowerBound: maxPlausibleSegment,
        wallEstimate: wall,
      );
    }
    return ElapsedKnown(segment: wall, source: ElapsedSource.wallClock);
  }

  /// The live elapsed time of a running session: [accumulated] work plus the
  /// resolved current segment. When the segment is ambiguous the accumulated
  /// duration plus the segment lower bound is returned as a floor.
  static Duration liveElapsed(
    Duration accumulated,
    ElapsedResolution resolution,
  ) {
    return switch (resolution) {
      ElapsedKnown(segment: final Duration s) => accumulated + s,
      ElapsedAmbiguous(lowerBound: final Duration lb) => accumulated + lb,
    };
  }

  static Duration _wallDelta(TimerTruth truth, TimerReading now) =>
      Duration(microseconds: now.wallUtcMicros - truth.wallAnchorUtcMicros);
}
