import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';

/// A deterministic habit occurrence key (R-HABIT-003).
///
/// For a dated schedule the key is the local date (`YYYY-MM-DD`). For an
/// aggregate schedule the key is the local `week_start_date` (`YYYY-MM-DD`) or
/// `month_key` (`YYYY-MM`). Every key carries an [anchor] local date used for
/// deterministic ordering and for walking periods backward/forward, plus a
/// canonical string [value] used as the stable persisted occurrence key.
final class HabitOccurrenceKey implements Comparable<HabitOccurrenceKey> {
  const HabitOccurrenceKey._({
    required this.value,
    required this.anchor,
    required this.scheduleKind,
    required this.frequency,
  });

  /// A dated key for [date].
  factory HabitOccurrenceKey.dated(LocalDate date) => HabitOccurrenceKey._(
    value: date.iso,
    anchor: date,
    scheduleKind: HabitScheduleKind.dated,
    frequency: HabitFrequency.daily,
  );

  /// A weekly aggregate key anchored at [weekStartDate].
  factory HabitOccurrenceKey.week(LocalDate weekStartDate) =>
      HabitOccurrenceKey._(
        value: weekStartDate.iso,
        anchor: weekStartDate,
        scheduleKind: HabitScheduleKind.aggregate,
        frequency: HabitFrequency.weekly,
      );

  /// A monthly aggregate key `YYYY-MM` anchored at the first of the month.
  factory HabitOccurrenceKey.month(LocalDate anyDayInMonth) {
    final LocalDate first = anyDayInMonth.firstDayOfMonth;
    final String key =
        '${first.year.toString().padLeft(4, '0')}-'
        '${first.month.toString().padLeft(2, '0')}';
    return HabitOccurrenceKey._(
      value: key,
      anchor: first,
      scheduleKind: HabitScheduleKind.aggregate,
      frequency: HabitFrequency.monthly,
    );
  }

  /// The canonical stable string persisted as the occurrence key.
  final String value;

  /// The local date used for ordering and period walking.
  final LocalDate anchor;

  final HabitScheduleKind scheduleKind;
  final HabitFrequency frequency;

  @override
  int compareTo(HabitOccurrenceKey other) {
    final int byAnchor = anchor.compareTo(other.anchor);
    return byAnchor != 0 ? byAnchor : value.compareTo(other.value);
  }

  bool operator <(HabitOccurrenceKey other) => compareTo(other) < 0;
  bool operator <=(HabitOccurrenceKey other) => compareTo(other) <= 0;
  bool operator >(HabitOccurrenceKey other) => compareTo(other) > 0;
  bool operator >=(HabitOccurrenceKey other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is HabitOccurrenceKey &&
      other.value == value &&
      other.frequency == frequency &&
      other.scheduleKind == scheduleKind;

  @override
  int get hashCode => Object.hash(value, frequency, scheduleKind);

  @override
  String toString() => value;
}
