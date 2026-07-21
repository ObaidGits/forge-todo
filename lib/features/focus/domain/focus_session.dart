import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';
import 'package:forge/features/focus/domain/focus_time_policy.dart';

/// An immutable focus-session aggregate (R-FOCUS-001, R-FOCUS-002, R-FOCUS-003).
///
/// A focus session is a top-level direct-area owner carrying
/// `(profileId, lifeAreaId)`. It MAY link to exactly one task, Learning
/// Resource, goal, or habit ([link]). Its timer truth is anchored, never
/// ticked: [wallAnchorUtc]/[monotonicAnchorMicros]/[bootSessionId] describe the
/// current running segment and [accumulatedDurationSec] holds the whole seconds
/// already completed by previous segments (R-FOCUS-002). The visible [status]
/// is a projection of the append-only event log.
final class FocusSession {
  FocusSession({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.mode,
    required this.status,
    required this.wallAnchorUtc,
    required this.monotonicAnchorMicros,
    required this.bootSessionId,
    required this.accumulatedDurationSec,
    required this.startedAtUtc,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.link,
    this.preset,
    this.plannedDurationSec,
    this.endedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (mode == FocusMode.interval) {
      if (plannedDurationSec == null || plannedDurationSec! <= 0) {
        throw const FormatException(
          'An interval session requires a positive planned duration.',
        );
      }
    } else if (plannedDurationSec != null) {
      throw const FormatException(
        'A count-up session must not carry a planned duration.',
      );
    }
    if (accumulatedDurationSec < 0) {
      throw const FormatException('accumulated duration must be nonnegative.');
    }
    if (monotonicAnchorMicros < 0) {
      throw const FormatException('monotonic anchor must be nonnegative.');
    }
    if (bootSessionId.isEmpty) {
      throw const FormatException('boot session id must not be empty.');
    }
    if (status.isTerminal && endedAtUtc == null) {
      throw const FormatException('A terminal session requires ended_at.');
    }
    if (!status.isTerminal && endedAtUtc != null) {
      throw const FormatException('An open session must not carry ended_at.');
    }
  }

  final FocusSessionId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;

  /// Optional single linked entity (R-FOCUS-001).
  final FocusLink? link;

  final FocusMode mode;

  /// The preset wire name recorded purely as provenance (R-FOCUS-004); null
  /// when the session was started without a named preset.
  final String? preset;

  /// The configured planned length in whole seconds for an interval session;
  /// null for a count-up session.
  final int? plannedDurationSec;

  final FocusSessionStatus status;

  /// Wall-clock anchor (UTC micros) of the current running segment.
  final int wallAnchorUtc;

  /// Monotonic anchor (elapsed-since-boot micros) of the current segment.
  final int monotonicAnchorMicros;

  /// Boot/session id the [monotonicAnchorMicros] was captured under.
  final String bootSessionId;

  /// Whole seconds of work completed by previous (paused/ended) segments.
  final int accumulatedDurationSec;

  /// The instant the session first started (its origin wall anchor).
  final int startedAtUtc;

  /// The instant the session reached a terminal state, or null while open.
  final int? endedAtUtc;

  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isOpen => status.isOpen;
  bool get isDeleted => deletedAtUtc != null;

  /// The timer truth of the current running segment (R-FOCUS-002).
  TimerTruth get timerTruth => TimerTruth(
    bootSessionId: bootSessionId,
    monotonicAnchor: Duration(microseconds: monotonicAnchorMicros),
    wallAnchorUtcMicros: wallAnchorUtc,
  );

  FocusSession copyWith({
    FocusSessionStatus? status,
    int? wallAnchorUtc,
    int? monotonicAnchorMicros,
    String? bootSessionId,
    int? accumulatedDurationSec,
    Object? endedAtUtc = _sentinel,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return FocusSession(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId,
      link: link,
      mode: mode,
      preset: preset,
      plannedDurationSec: plannedDurationSec,
      status: status ?? this.status,
      wallAnchorUtc: wallAnchorUtc ?? this.wallAnchorUtc,
      monotonicAnchorMicros:
          monotonicAnchorMicros ?? this.monotonicAnchorMicros,
      bootSessionId: bootSessionId ?? this.bootSessionId,
      accumulatedDurationSec:
          accumulatedDurationSec ?? this.accumulatedDurationSec,
      startedAtUtc: startedAtUtc,
      endedAtUtc: endedAtUtc == _sentinel
          ? this.endedAtUtc
          : endedAtUtc as int?,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  static const Object _sentinel = Object();
}
