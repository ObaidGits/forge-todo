import 'package:forge/core/domain/id.dart';

/// A presentation-safe snapshot of the active focus session surfaced on Today
/// (R-HOME-001, R-HOME-003, R-FOCUS-001..003).
///
/// It carries everything the Today focus slot needs to render and open the
/// session without importing the focus domain: the opaque session id, the
/// visible status and mode wire values, an optional linked-entity label, and
/// the anchored duration facts (accumulated whole seconds plus the optional
/// planned length for an interval session). Live elapsed time is never a stored
/// ticking value — the UI derives the running segment from the timer truth
/// (R-FOCUS-002) — so this snapshot only reports the durable anchors.
final class FocusTodaySnapshot {
  const FocusTodaySnapshot({
    required this.sessionId,
    required this.statusWire,
    required this.modeWire,
    required this.accumulatedDurationSec,
    this.plannedDurationSec,
    this.linkLabel,
  });

  /// The opaque focus session id (opens `/focus/<id>`).
  final String sessionId;

  /// Stable session status wire value: `running` or `paused` (an open session).
  final String statusWire;

  /// Stable session mode wire value: `count_up` or `interval`.
  final String modeWire;

  /// Whole seconds of work completed by previously-closed segments.
  final int accumulatedDurationSec;

  /// The planned length in whole seconds for an interval session; null for a
  /// count-up session.
  final int? plannedDurationSec;

  /// A short label for the linked entity (task/resource/goal/habit), or null
  /// when the session has no link.
  final String? linkLabel;

  bool get isRunning => statusWire == 'running';
  bool get isPaused => statusWire == 'paused';
}

/// The exported focus application contract that surfaces the active session for
/// Today (R-HOME-001, R-FOCUS-001..003).
///
/// Home composes this contract only — never the focus feature's domain
/// repository or infrastructure (design.md §4). Focus sessions are started ad
/// hoc rather than scheduled, so there is no "next" session; the contract
/// returns the single open (running or paused) session or null when none is
/// open (R-FOCUS-003 one-open constraint). It is a pure read: surfacing it never
/// mutates any focus row (R-HOME-005).
abstract interface class FocusTodayContract {
  /// The single open focus session for [profileId], optionally scoped to
  /// [lifeAreaId], or null when none is open.
  Future<FocusTodaySnapshot?> activeSession(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  });
}
