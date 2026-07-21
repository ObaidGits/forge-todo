import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';

/// An immutable schedule version of a recurring task series (R-TASK-006,
/// R-TASK-007).
///
/// A recurring task is a chain of schedule versions sharing a [seriesId]. Each
/// version pins a [RecurrenceRule] and the [effectiveOccurrenceKey] from which
/// it governs the series. Completing occurrences never rewrites the version
/// that generated their history; editing recurrence "this and future" closes
/// the current version (sets [closedAtOccurrenceKey]) and appends a successor
/// with an incremented [version] and a [predecessorId] link. Generated
/// historical keys and events therefore remain immutable.
final class RecurrenceScheduleVersion {
  RecurrenceScheduleVersion({
    required this.id,
    required this.seriesId,
    required this.version,
    required this.effectiveOccurrenceKey,
    required this.rule,
    this.predecessorId,
    this.closedAtOccurrenceKey,
    this.strategyVersion = 1,
  }) {
    if (version < 1) {
      throw FormatException('Schedule version must be >= 1: $version');
    }
    if (strategyVersion < 1) {
      throw FormatException('Strategy version must be >= 1: $strategyVersion');
    }
    final LocalDate? closed = closedAtOccurrenceKey;
    if (closed != null && closed < effectiveOccurrenceKey) {
      throw const FormatException(
        'A version cannot close before it becomes effective.',
      );
    }
  }

  final String id;
  final String seriesId;
  final int version;

  /// The first occurrence key (local date) this version governs. Occurrences
  /// strictly before this key belong to a predecessor version.
  final LocalDate effectiveOccurrenceKey;

  final RecurrenceRule rule;

  /// The predecessor version id, or null for the first version of a series.
  final String? predecessorId;

  /// When set, this version stops governing occurrences on or after this key
  /// because a successor superseded it ("this and future" edit). Null while the
  /// version is the open tail of the series.
  final LocalDate? closedAtOccurrenceKey;

  /// The engine strategy version used to interpret [rule]. Bumping it lets a
  /// future engine change occurrence math without reinterpreting old versions.
  final int strategyVersion;

  /// Whether this version has been superseded by a successor.
  bool get isClosed => closedAtOccurrenceKey != null;

  /// The exclusive upper bound (local date) of occurrences this version owns,
  /// or null when the version is open-ended. Occurrences with a key `>=` this
  /// value belong to the successor.
  LocalDate? get exclusiveUpperBound => closedAtOccurrenceKey;

  RecurrenceScheduleVersion close(LocalDate atOccurrenceKey) =>
      RecurrenceScheduleVersion(
        id: id,
        seriesId: seriesId,
        version: version,
        effectiveOccurrenceKey: effectiveOccurrenceKey,
        rule: rule,
        predecessorId: predecessorId,
        closedAtOccurrenceKey: atOccurrenceKey,
        strategyVersion: strategyVersion,
      );
}
