import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// An immutable schedule + target version of a habit (R-HABIT-001, R-HABIT-003).
///
/// A habit is a chain of schedule versions sharing the owning habit id. Each
/// version pins a [HabitScheduleRule] and a [HabitTarget] and the
/// [effectiveOccurrenceKey] local date from which it governs the habit.
/// Occurrences never rewrite the version that generated them; editing schedule
/// or target semantics closes the current version (sets
/// [closedAtOccurrenceKey]) and appends a successor with an incremented
/// [version] and a [predecessorId] link at an explicit effective occurrence key
/// (R-HABIT-003). Every occurrence binds the version effective at its key and
/// prior occurrences are never reinterpreted.
final class HabitScheduleVersion {
  HabitScheduleVersion({
    required this.id,
    required this.habitId,
    required this.version,
    required this.effectiveOccurrenceKey,
    required this.rule,
    required this.target,
    this.predecessorId,
    this.closedAtOccurrenceKey,
    this.ruleVersion = 1,
  }) {
    if (version < 1) {
      throw FormatException('Schedule version must be >= 1: $version');
    }
    if (ruleVersion < 1) {
      throw FormatException('Rule version must be >= 1: $ruleVersion');
    }
    final LocalDate? closed = closedAtOccurrenceKey;
    if (closed != null && closed < effectiveOccurrenceKey) {
      throw const FormatException(
        'A version cannot close before it becomes effective.',
      );
    }
  }

  final String id;
  final String habitId;
  final int version;

  /// The first occurrence-anchor local date this version governs. Occurrences
  /// whose anchor is strictly before this belong to a predecessor version.
  final LocalDate effectiveOccurrenceKey;

  final HabitScheduleRule rule;
  final HabitTarget target;

  /// The predecessor version id, or null for the first version of a habit.
  final String? predecessorId;

  /// When set, this version stops governing occurrences whose anchor is on or
  /// after this date because a successor superseded it. Null while open.
  final LocalDate? closedAtOccurrenceKey;

  /// The version of the interpretation strategy used to read [rule]/[target].
  final int ruleVersion;

  /// Whether this version has been superseded by a successor.
  bool get isClosed => closedAtOccurrenceKey != null;

  /// The exclusive upper bound (anchor date) of occurrences this version owns,
  /// or null when open-ended.
  LocalDate? get exclusiveUpperBound => closedAtOccurrenceKey;

  /// A copy of this version closed at [atOccurrenceKey].
  HabitScheduleVersion close(LocalDate atOccurrenceKey) => HabitScheduleVersion(
    id: id,
    habitId: habitId,
    version: version,
    effectiveOccurrenceKey: effectiveOccurrenceKey,
    rule: rule,
    target: target,
    predecessorId: predecessorId,
    closedAtOccurrenceKey: atOccurrenceKey,
    ruleVersion: ruleVersion,
  );
}
