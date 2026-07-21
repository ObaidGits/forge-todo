/// A day of the week for a recurrence `BYDAY` selection (R-TASK-005).
///
/// [isoWeekday] matches `DateTime.weekday` and [LocalDate.weekday] (Monday = 1
/// … Sunday = 7). The [wire] tokens are the two-letter RFC-5545 codes so a
/// stored rule reads like the standard it mirrors.
enum RecurrenceWeekday {
  monday(1, 'MO'),
  tuesday(2, 'TU'),
  wednesday(3, 'WE'),
  thursday(4, 'TH'),
  friday(5, 'FR'),
  saturday(6, 'SA'),
  sunday(7, 'SU');

  const RecurrenceWeekday(this.isoWeekday, this.wire);

  /// ISO weekday number (Monday = 1 … Sunday = 7).
  final int isoWeekday;

  /// Two-letter RFC-5545 `BYDAY` token.
  final String wire;

  /// Decodes an RFC-5545 token, throwing [FormatException] for unknown values.
  static RecurrenceWeekday fromWire(String wire) {
    for (final RecurrenceWeekday day in RecurrenceWeekday.values) {
      if (day.wire == wire) {
        return day;
      }
    }
    throw FormatException('Unknown recurrence weekday: $wire');
  }

  /// Resolves an ISO weekday number (1..7) to its enum value.
  static RecurrenceWeekday fromIso(int isoWeekday) {
    for (final RecurrenceWeekday day in RecurrenceWeekday.values) {
      if (day.isoWeekday == isoWeekday) {
        return day;
      }
    }
    throw FormatException('ISO weekday must be 1..7: $isoWeekday');
  }
}
