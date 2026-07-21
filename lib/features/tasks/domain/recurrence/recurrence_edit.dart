import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_engine.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_schedule_version.dart';

/// The scope a recurrence edit applies to (R-TASK-007).
enum RecurrenceEditScope {
  /// Change only the selected occurrence, leaving the series intact.
  thisOccurrence,

  /// Close the current schedule version at the selected occurrence and start a
  /// successor version from it forward.
  thisAndFuture,
}

/// The result of a "this and future" split: the closed predecessor and the new
/// successor version, both immutable (R-TASK-007).
final class RecurrenceSplit {
  const RecurrenceSplit({required this.closed, required this.successor});

  /// The predecessor version, now closed at the effective key.
  final RecurrenceScheduleVersion closed;

  /// The successor version governing occurrences from the effective key.
  final RecurrenceScheduleVersion successor;
}

/// Pure policies for recurrence edits and version-scoped occurrence generation
/// (R-TASK-006, R-TASK-007).
abstract final class RecurrencePolicies {
  /// Splits [current] at [effectiveKey], closing it and creating a successor
  /// with [newRule].
  ///
  /// [effectiveKey] must be a real occurrence of the current version and must
  /// not precede the version's own effective key. The successor's rule keeps
  /// [effectiveKey] as its own start so its pattern is anchored there. The
  /// predecessor generates occurrences strictly before [effectiveKey]; the
  /// successor governs [effectiveKey] onward. Historical keys stay immutable.
  static RecurrenceSplit split({
    required RecurrenceScheduleVersion current,
    required LocalDate effectiveKey,
    required RecurrenceRule newRule,
    required String successorId,
  }) {
    if (current.isClosed) {
      throw StateError('Cannot split an already-closed schedule version.');
    }
    if (effectiveKey < current.effectiveOccurrenceKey) {
      throw const FormatException(
        'Effective key cannot precede the current version.',
      );
    }
    return RecurrenceSplit(
      closed: current.close(effectiveKey),
      successor: RecurrenceScheduleVersion(
        id: successorId,
        seriesId: current.seriesId,
        version: current.version + 1,
        effectiveOccurrenceKey: effectiveKey,
        predecessorId: current.id,
        rule: newRule,
        strategyVersion: current.strategyVersion,
      ),
    );
  }

  /// The next real occurrence a completion should advance the series to, or
  /// null when the version has no further occurrence.
  ///
  /// Occurrences beyond the version's [RecurrenceScheduleVersion.closedAtOccurrenceKey]
  /// belong to the successor and are not returned here.
  static LocalDate? nextForVersion(
    RecurrenceScheduleVersion version,
    LocalDate afterKey,
  ) {
    final LocalDate? candidate = RecurrenceEngine.next(version.rule, afterKey);
    if (candidate == null) {
      return null;
    }
    final LocalDate? bound = version.exclusiveUpperBound;
    if (bound != null && candidate >= bound) {
      return null;
    }
    return candidate;
  }

  /// The first real occurrence a version governs on or after its effective key,
  /// respecting its close bound.
  static LocalDate? firstForVersion(RecurrenceScheduleVersion version) {
    final List<LocalDate> keys = occurrencesForVersion(version, limit: 1);
    return keys.isEmpty ? null : keys.first;
  }

  /// The real occurrences a version governs: on or after its effective key,
  /// strictly before its close bound, up to [limit].
  static List<LocalDate> occurrencesForVersion(
    RecurrenceScheduleVersion version, {
    required int limit,
  }) {
    final List<LocalDate> result = <LocalDate>[];
    final LocalDate? bound = version.exclusiveUpperBound;
    for (final LocalDate key in RecurrenceEngine.take(
      version.rule,
      from: version.effectiveOccurrenceKey,
      // Over-fetch so close-bound filtering still returns up to [limit].
      limit: bound == null ? limit : limit + 366,
    )) {
      if (bound != null && key >= bound) {
        break;
      }
      result.add(key);
      if (result.length >= limit) {
        break;
      }
    }
    return result;
  }
}
