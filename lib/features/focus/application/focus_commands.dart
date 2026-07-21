import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_preset.dart';

/// Input to start a focus session (R-FOCUS-001, R-FOCUS-004).
///
/// Either supply a [preset] (which resolves mode + planned duration) or supply
/// [mode] and, for an interval session, [plannedDurationSec] explicitly. A
/// preset always wins when present; it is stored purely as provenance.
final class StartFocusSessionInput {
  const StartFocusSessionInput({
    required this.lifeAreaId,
    this.preset,
    this.mode,
    this.plannedDurationSec,
    this.link,
  });

  /// A count-up session in [lifeAreaId] with no preset or planned duration.
  ///
  /// Exposed on the application boundary so callers (for example the Today
  /// screen's inline "Start focus") can start the common count-up session
  /// without importing the focus domain's [FocusMode] (design.md §4/§16).
  const StartFocusSessionInput.countUp({required this.lifeAreaId, this.link})
    : preset = null,
      mode = FocusMode.countUp,
      plannedDurationSec = null;

  final String lifeAreaId;

  /// A named preset. When set, its mode/planned duration are used (R-FOCUS-004).
  final FocusPreset? preset;

  /// The explicit mode when no preset is supplied.
  final FocusMode? mode;

  /// The explicit planned duration for an interval session with no preset.
  final int? plannedDurationSec;

  /// Optional single linked entity (R-FOCUS-001).
  final FocusLink? link;
}

/// Input to pause the open session (R-FOCUS-003).
final class PauseFocusSessionInput {
  const PauseFocusSessionInput({required this.sessionId});
  final String sessionId;
}

/// Input to resume the open (paused) session (R-FOCUS-003).
final class ResumeFocusSessionInput {
  const ResumeFocusSessionInput({required this.sessionId});
  final String sessionId;
}

/// Input to end the open session (R-FOCUS-003).
final class EndFocusSessionInput {
  const EndFocusSessionInput({required this.sessionId});
  final String sessionId;
}

/// Input to cancel (abandon) the open session (R-FOCUS-003).
final class CancelFocusSessionInput {
  const CancelFocusSessionInput({required this.sessionId});
  final String sessionId;
}

/// Input to correct a session's recorded duration by appending an audit event
/// (R-FOCUS-002 correction, R-FOCUS-003 append-only, R-FOCUS-005 audited).
///
/// The correction records the intended accumulated work duration in whole
/// seconds; the prior events and intervals are never rewritten.
final class CorrectFocusSessionInput {
  const CorrectFocusSessionInput({
    required this.sessionId,
    required this.correctedDurationSec,
    this.reason,
  });

  final String sessionId;
  final int correctedDurationSec;
  final String? reason;
}
