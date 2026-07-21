/// A timezone-free calendar date (`YYYY-MM-DD`) with no time-of-day.
///
/// Date-only intent is stored separately from instants (R-GEN-004). A
/// [LocalDate] is pure value data: it carries no timezone and performs
/// deterministic proleptic-Gregorian arithmetic, so recurrence math is
/// reproducible regardless of the host platform's clock or locale.
///
/// Internally the date delegates calendar rules to `DateTime.utc`, which is a
/// pure `dart:core` calendar with a fixed (UTC) offset and therefore free of
/// any DST or timezone behavior. No wall-clock conversion happens here; that is
/// the sole responsibility of a `TimeZoneResolver`.
final class LocalDate implements Comparable<LocalDate> {
  /// Builds a date, validating that [day] exists in [month]/[year].
  factory LocalDate(int year, int month, int day) {
    if (month < 1 || month > 12) {
      throw FormatException('Month must be 1..12: $month');
    }
    final int max = _daysInMonth(year, month);
    if (day < 1 || day > max) {
      throw FormatException('Day $day is out of range for $year-$month.');
    }
    return LocalDate._(year, month, day);
  }

  const LocalDate._(this.year, this.month, this.day);

  /// Parses an ISO `YYYY-MM-DD` value with strict range validation.
  factory LocalDate.parse(String iso) {
    final Match? match = _isoPattern.firstMatch(iso);
    if (match == null) {
      throw FormatException('Expected ISO YYYY-MM-DD: $iso');
    }
    return LocalDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int year;
  final int month;
  final int day;

  static final RegExp _isoPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// The ISO `YYYY-MM-DD` rendering used as a deterministic occurrence key.
  String get iso => '${_pad(year, 4)}-${_pad(month, 2)}-${_pad(day, 2)}';

  /// ISO weekday, Monday = 1 … Sunday = 7.
  int get weekday => DateTime.utc(year, month, day).weekday;

  /// The number of days in this date's month.
  int get daysInMonth => _daysInMonth(year, month);

  /// Returns the date [count] days after this one (negative moves backward).
  LocalDate addDays(int count) {
    final DateTime moved = DateTime.utc(
      year,
      month,
      day,
    ).add(Duration(days: count));
    return LocalDate._(moved.year, moved.month, moved.day);
  }

  /// Returns the date [count] months after this one.
  ///
  /// When the original [day] does not exist in the target month (for example
  /// day 31 in a 30-day month) the result is clamped to the last valid day of
  /// that month. Callers that require strict RFC-5545 "skip" semantics for a
  /// `BYMONTHDAY` value should test [monthHasDay] instead of relying on clamp.
  LocalDate addMonths(int count) {
    final int zeroBased = (month - 1) + count;
    final int targetYear = year + _floorDiv(zeroBased, 12);
    final int targetMonth = _floorMod(zeroBased, 12) + 1;
    final int max = _daysInMonth(targetYear, targetMonth);
    return LocalDate._(targetYear, targetMonth, day < max ? day : max);
  }

  /// Returns the date [count] years after this one, clamping Feb 29 to Feb 28
  /// in non-leap years.
  LocalDate addYears(int count) => addMonths(count * 12);

  /// Whether the given [dayOfMonth] exists in this date's month/year.
  bool monthHasDay(int dayOfMonth) =>
      dayOfMonth >= 1 && dayOfMonth <= daysInMonth;

  /// The first day of this date's month.
  LocalDate get firstDayOfMonth => LocalDate._(year, month, 1);

  /// The last day of this date's month.
  LocalDate get lastDayOfMonth => LocalDate._(year, month, daysInMonth);

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) {
      return year.compareTo(other.year);
    }
    if (month != other.month) {
      return month.compareTo(other.month);
    }
    return day.compareTo(other.day);
  }

  bool operator <(LocalDate other) => compareTo(other) < 0;
  bool operator <=(LocalDate other) => compareTo(other) <= 0;
  bool operator >(LocalDate other) => compareTo(other) > 0;
  bool operator >=(LocalDate other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;

  static int _daysInMonth(int year, int month) {
    const List<int> lengths = <int>[
      31,
      28,
      31,
      30,
      31,
      30,
      31,
      31,
      30,
      31,
      30,
      31,
    ];
    if (month == 2 && _isLeapYear(year)) {
      return 29;
    }
    return lengths[month - 1];
  }

  static bool _isLeapYear(int year) =>
      (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  static int _floorDiv(int a, int b) => (a - _floorMod(a, b)) ~/ b;

  static int _floorMod(int a, int b) => ((a % b) + b) % b;

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}
