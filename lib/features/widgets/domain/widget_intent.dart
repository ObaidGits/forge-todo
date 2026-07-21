/// Widget-originated intents and their authentication envelope
/// (R-WIDGET-003).
///
/// A widget tap (complete a task, check in a habit) arrives from an untrusted
/// surface. A [WidgetIntent] is therefore an authenticated envelope: it binds
/// the owning [profileId], the target entity, an [issuedAtUtcMicros] timestamp,
/// a stable [intentId] used for idempotency, and an authentication [token] over
/// the canonical payload. Verification (in the application layer) rejects a
/// spoofed, tampered, replayed, or cross-profile intent before any command
/// runs, so a forged intent can never drive a durable write.
library;

import 'dart:convert';

/// The durable actions a widget may request. Deliberately a small allowlist;
/// unknown actions are rejected.
enum WidgetIntentAction {
  /// Complete a task shown on the Today Tasks widget.
  completeTask('complete_task'),

  /// Record a check-in for a habit shown on the Habit Checklist widget.
  checkInHabit('check_in_habit');

  const WidgetIntentAction(this.wireName);

  final String wireName;

  /// Unknown-safe decoding: an unrecognized action returns null so a spoofed or
  /// newer action name is rejected rather than misinterpreted.
  static WidgetIntentAction? fromWire(String? wireName) {
    if (wireName == null) {
      return null;
    }
    for (final WidgetIntentAction action in WidgetIntentAction.values) {
      if (action.wireName == wireName) {
        return action;
      }
    }
    return null;
  }
}

/// Why a widget intent was rejected. Mapped to a stable failure by the verifier.
enum WidgetIntentRejection {
  /// The signed [WidgetIntent.token] did not match the canonical payload
  /// (tampered or forged).
  invalidSignature,

  /// The intent named a profile other than the active local profile (spoof).
  profileMismatch,

  /// The intent's timestamp is outside the accepted freshness window (a stale
  /// or replayed token).
  expired,

  /// The intent's timestamp is implausibly in the future beyond tolerance.
  future,

  /// The action or target was malformed/empty.
  malformed,
}

/// An authenticated widget-originated command envelope.
final class WidgetIntent {
  WidgetIntent({
    required this.intentId,
    required this.profileId,
    required this.action,
    required this.surfaceWire,
    required this.targetEntityId,
    required this.issuedAtUtcMicros,
    required this.token,
  }) {
    if (intentId.isEmpty) {
      throw ArgumentError.value(intentId, 'intentId', 'Must not be empty.');
    }
  }

  /// Stable, unique id for this tap. Drives the derived command id so a
  /// double-tap / re-delivered intent maps to the same durable command and
  /// therefore the same committed receipt (idempotency).
  final String intentId;

  final String profileId;
  final WidgetIntentAction action;
  final String surfaceWire;
  final String targetEntityId;

  /// When the widget issued the intent (UTC microseconds).
  final int issuedAtUtcMicros;

  /// Authentication tag over [canonicalPayload]. Verified against the shared
  /// bridge secret; a mismatch is [WidgetIntentRejection.invalidSignature].
  final String token;

  /// The canonical, signable payload. Excludes the [token] itself and sorts
  /// keys so signing and verification always operate on identical bytes.
  String canonicalPayload() => jsonEncode(<String, Object?>{
    'action': action.wireName,
    'intent_id': intentId,
    'issued_at_utc_micros': issuedAtUtcMicros,
    'profile_id': profileId,
    'surface': surfaceWire,
    'target_entity_id': targetEntityId,
  });

  /// Whether the envelope is structurally well-formed (non-empty target). The
  /// verifier still performs signature/freshness/ownership checks.
  bool get isWellFormed => targetEntityId.isNotEmpty;
}

/// A verified widget command: the trusted, internal form produced only after a
/// [WidgetIntent] passes every authentication and freshness check.
final class VerifiedWidgetCommand {
  const VerifiedWidgetCommand({
    required this.intentId,
    required this.profileId,
    required this.action,
    required this.surfaceWire,
    required this.targetEntityId,
    required this.canonicalPayload,
  });

  final String intentId;
  final String profileId;
  final WidgetIntentAction action;
  final String surfaceWire;
  final String targetEntityId;

  /// The canonical payload that was authenticated. Reused as the durable
  /// command's request hash input so replay detection is stable.
  final String canonicalPayload;

  /// Deterministic durable command id derived from the intent id. The same
  /// intent always yields the same command id, so the command bus receipt makes
  /// replay idempotent (R-GEN-005, R-WIDGET-003).
  String get derivedCommandId => 'widget-$intentId';
}
