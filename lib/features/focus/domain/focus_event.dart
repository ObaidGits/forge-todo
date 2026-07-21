import 'package:forge/features/focus/domain/focus_event_kind.dart';

/// An immutable focus-session lifecycle event (R-FOCUS-003).
///
/// Every start/pause/resume/end/cancel/correction appends one event. Events
/// carry both a wall stamp and, when available, a monotonic stamp plus the boot
/// id they were taken under, so the audit log preserves the same time truth as
/// the session (R-FOCUS-002). Corrections append a [FocusEventKind.corrected]
/// event that [supersedesId] a prior event; nothing is ever rewritten
/// (R-FOCUS-003, R-FOCUS-005).
final class FocusEvent {
  const FocusEvent({
    required this.id,
    required this.profileId,
    required this.sessionId,
    required this.kind,
    required this.wallAtUtc,
    required this.bootSessionId,
    required this.payloadVersion,
    required this.occurredAtUtc,
    this.commandId,
    this.monotonicMicros,
    this.payload,
    this.supersedesId,
  });

  final String id;
  final String profileId;
  final String sessionId;
  final FocusEventKind kind;
  final String? commandId;

  /// Wall-clock stamp (UTC micros) of the event.
  final int wallAtUtc;

  /// Monotonic stamp (elapsed-since-boot micros), or null when unavailable.
  final int? monotonicMicros;

  /// Boot/session id the stamps were captured under.
  final String bootSessionId;

  final String? payload;
  final int payloadVersion;
  final int occurredAtUtc;

  /// The prior event this one supersedes, when correcting/undoing.
  final String? supersedesId;
}
