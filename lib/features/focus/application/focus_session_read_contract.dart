import 'package:forge/core/domain/id.dart';

/// A presentation-safe projection of one projected focus interval (R-FOCUS-003).
///
/// It carries only primitive facts — the interval kind wire value and its
/// wall-clock bounds — so the presentation layer can render a session's
/// work/pause breakdown without importing the focus domain.
final class FocusIntervalView {
  const FocusIntervalView({
    required this.kindWire,
    required this.startedAtUtc,
    this.endedAtUtc,
  });

  /// Stable interval kind wire value: `work` or `pause`.
  final String kindWire;

  /// Wall-clock start (UTC micros).
  final int startedAtUtc;

  /// Wall-clock end (UTC micros), or null while the interval is still open.
  final int? endedAtUtc;

  bool get isOpen => endedAtUtc == null;

  /// The whole-second length of a closed interval; zero while still open.
  int get durationSec {
    final int? end = endedAtUtc;
    if (end == null) {
      return 0;
    }
    final int micros = end - startedAtUtc;
    return micros <= 0 ? 0 : micros ~/ 1000000;
  }
}

/// A presentation-safe read projection of a single focus session (R-FOCUS-003).
///
/// It reports the durable facts a read-only detail surface needs — the visible
/// status/mode wire values, the anchored accumulated work seconds, the optional
/// planned length and linked-entity label, the start/end instants, and the
/// projected work/pause intervals — without exposing the focus domain. Elapsed
/// time is reported as the durable [accumulatedDurationSec] anchor; a read-only
/// detail never ticks a live segment (R-FOCUS-002).
final class FocusSessionDetail {
  const FocusSessionDetail({
    required this.sessionId,
    required this.statusWire,
    required this.modeWire,
    required this.accumulatedDurationSec,
    required this.startedAtUtc,
    required this.intervals,
    this.plannedDurationSec,
    this.linkLabel,
    this.endedAtUtc,
  });

  final String sessionId;

  /// Stable status wire value: `running`, `paused`, `completed`, `cancelled`.
  final String statusWire;

  /// Stable mode wire value: `count_up` or `interval`.
  final String modeWire;

  /// Whole seconds of work completed by closed segments (the durable anchor).
  final int accumulatedDurationSec;

  /// The planned length in whole seconds for an interval session; null for a
  /// count-up session.
  final int? plannedDurationSec;

  /// A short wire label for the linked entity (`task`/`course`/`goal`/`habit`),
  /// or null when the session has no link.
  final String? linkLabel;

  /// The instant the session first started (UTC micros).
  final int startedAtUtc;

  /// The instant the session reached a terminal state, or null while open.
  final int? endedAtUtc;

  /// The projected work/pause intervals, ordered by start.
  final List<FocusIntervalView> intervals;

  bool get isRunning => statusWire == 'running';
  bool get isPaused => statusWire == 'paused';
  bool get isCompleted => statusWire == 'completed';
  bool get isCancelled => statusWire == 'cancelled';
  bool get isInterval => modeWire == 'interval';
}

/// The exported focus application contract that surfaces a single session's
/// read-only detail (R-FOCUS-003).
///
/// A per-session detail surface composes this contract only — never the focus
/// feature's domain repository or infrastructure (design.md §4). It is a pure
/// read: surfacing a session never mutates any focus row (R-HOME-005).
abstract interface class FocusSessionReadContract {
  /// The read-only detail for [sessionId], or null when absent for [profileId].
  Future<FocusSessionDetail?> sessionDetail(
    ProfileId profileId,
    FocusSessionId sessionId,
  );
}
