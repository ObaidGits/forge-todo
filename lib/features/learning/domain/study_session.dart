import 'package:forge/features/learning/domain/study_session_event_kind.dart';

/// An immutable study-session version row (R-LEARN-002, R-FOCUS-005).
///
/// A study session is identified by a stable [logicalId]. Every mutation
/// appends a new version row rather than editing an earlier one; the newest
/// version carries `isCurrent = true` and points back through [supersedesId].
/// The substantive facts (`started/ended/duration/note/item/focus`) of a
/// version row are never rewritten — corrections create a superseding version.
///
/// Instants ([startedAtUtc], [endedAtUtc]) are integer UTC microseconds
/// (platform convention); [durationSec] is the interval length in whole seconds
/// (data-model duration convention). The `[startedAtUtc, endedAtUtc]` window is
/// the study-side duration contract consumed by combined focus/study metrics:
/// durations are unioned by interval, never summed as independent time
/// (R-FOCUS-005).
final class StudySession {
  StudySession({
    required this.id,
    required this.profileId,
    required this.courseId,
    required this.logicalId,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.durationSec,
    required this.version,
    required this.isCurrent,
    required this.createdAtUtc,
    this.itemId,
    this.focusSessionId,
    this.note,
    this.supersedesId,
  }) {
    if (endedAtUtc < startedAtUtc) {
      throw FormatException(
        'Study session end ($endedAtUtc) precedes start ($startedAtUtc).',
      );
    }
    if (durationSec < 0) {
      throw FormatException(
        'durationSec must be nonnegative, got $durationSec.',
      );
    }
    if (version < 1) {
      throw FormatException('version must be >= 1, got $version.');
    }
  }

  final String id;
  final String profileId;
  final String courseId;

  /// The stable logical session id shared across all versions of one session.
  final String logicalId;

  /// Session start as integer UTC microseconds.
  final int startedAtUtc;

  /// Session end as integer UTC microseconds.
  final int endedAtUtc;

  /// The session length in whole seconds, derived from the interval span.
  final int durationSec;

  /// Optional item this session studied (R-LEARN-003 resume uses it).
  final String? itemId;

  /// Optional linked focus session (R-FOCUS-005); no FK because focus tables
  /// land in a later wave.
  final String? focusSessionId;

  final String? note;

  final int version;

  /// The version row this one supersedes, or null for the first version.
  final String? supersedesId;

  /// Whether this is the current version of the logical session.
  final bool isCurrent;

  final int createdAtUtc;

  /// The number of microseconds in one second, used to derive [durationSec]
  /// from the microsecond interval.
  static const int microsPerSecond = 1000000;
}

/// An immutable study-session lifecycle event (R-LEARN-002).
final class StudySessionEvent {
  const StudySessionEvent({
    required this.id,
    required this.profileId,
    required this.sessionId,
    required this.logicalId,
    required this.kind,
    required this.payloadVersion,
    required this.occurredAtUtc,
    this.commandId,
    this.payload,
    this.supersedesId,
  });

  final String id;
  final String profileId;

  /// The `study_sessions` version row this event produced or affected.
  final String sessionId;
  final String logicalId;
  final StudySessionEventKind kind;
  final String? commandId;
  final String? payload;
  final int payloadVersion;
  final int occurredAtUtc;

  /// The prior version row this event supersedes, when correcting/undoing.
  final String? supersedesId;
}
