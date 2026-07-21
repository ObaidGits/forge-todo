import 'package:forge/features/focus/domain/focus_interval_kind.dart';
import 'package:forge/features/focus/domain/focus_policies.dart';

/// An immutable projected focus interval (R-FOCUS-003).
///
/// Intervals are a projection derived from the event log: each work segment and
/// each pause becomes one interval. An interval is *open* while [endedAtUtc] is
/// null (the current running work segment or an ongoing pause). Only one
/// interval per profile may be open at a time and no two intervals may overlap
/// (R-FOCUS-003); those invariants are enforced by the persistence layer.
final class FocusInterval {
  const FocusInterval({
    required this.id,
    required this.profileId,
    required this.sessionId,
    required this.kind,
    required this.startedAtUtc,
    required this.bootSessionId,
    required this.createdAtUtc,
    this.endedAtUtc,
    this.monotonicStartMicros,
    this.monotonicEndMicros,
  });

  final String id;
  final String profileId;
  final String sessionId;
  final FocusIntervalKind kind;

  /// Wall-clock start (UTC micros).
  final int startedAtUtc;

  /// Wall-clock end (UTC micros), or null while the interval is open.
  final int? endedAtUtc;

  final int? monotonicStartMicros;
  final int? monotonicEndMicros;
  final String bootSessionId;
  final int createdAtUtc;

  bool get isOpen => endedAtUtc == null;

  /// The half-open span of a closed interval, for interval-union metrics
  /// (R-FOCUS-005). Throws when the interval is still open.
  FocusTimeSpan get span {
    final int? end = endedAtUtc;
    if (end == null) {
      throw StateError('An open interval has no bounded span.');
    }
    return FocusTimeSpan(startUtc: startedAtUtc, endUtc: end);
  }
}
