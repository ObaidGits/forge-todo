import 'package:forge/core/domain/local_date.dart';

/// The aggregation window of a V1 weekly or monthly Insight (R-INSIGHT-001,
/// R-INSIGHT-002).
///
/// A weekly/monthly Insight is aggregated from the immutable factual daily
/// closes of the days it contains, so the window is expressed as the ordered
/// list of ISO `YYYY-MM-DD` [dayKeys] that fall inside it plus the UTC instants
/// that bound the same window for the interval-unioned focus/study time. Keys
/// are derived purely from calendar arithmetic (no wall clock), so the same
/// anchor date always yields the same window on every device and run.
enum InsightPeriodKind {
  weekly('weekly'),
  monthly('monthly');

  const InsightPeriodKind(this.wire);

  /// Stable lowercase persistence/label value.
  final String wire;

  static InsightPeriodKind fromWire(String wire) {
    for (final InsightPeriodKind kind in InsightPeriodKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown insight period kind: $wire');
  }
}

/// A resolved weekly or monthly aggregation window.
final class InsightPeriod {
  InsightPeriod({
    required this.kind,
    required this.periodKey,
    required this.timezoneId,
    required this.rangeStartUtc,
    required this.rangeEndUtc,
    required List<String> dayKeys,
  }) : dayKeys = List<String>.unmodifiable(dayKeys) {
    if (rangeEndUtc < rangeStartUtc) {
      throw FormatException(
        'Range end ($rangeEndUtc) precedes start ($rangeStartUtc).',
      );
    }
    if (dayKeys.isEmpty) {
      throw const FormatException('An insight period must contain days.');
    }
  }

  /// Builds the weekly window containing [anchor].
  ///
  /// The window starts on [weekStart] (an ISO weekday, Monday = 1) and always
  /// spans exactly seven days. The stable persisted key uses the ISO-8601 week
  /// so it matches the planner's weekly record for the same physical week.
  /// [rangeStartUtc]/[rangeEndUtc] are the caller-resolved UTC bounds of the
  /// window used for the interval-unioned focus/study time (R-GEN-004).
  factory InsightPeriod.weekly(
    LocalDate anchor, {
    required String timezoneId,
    required int rangeStartUtc,
    required int rangeEndUtc,
    int weekStart = DateTime.monday,
  }) {
    if (weekStart < DateTime.monday || weekStart > DateTime.sunday) {
      throw FormatException(
        'week_start must be an ISO weekday 1..7: $weekStart',
      );
    }
    final int offset = ((anchor.weekday - weekStart) % 7 + 7) % 7;
    final LocalDate start = anchor.addDays(-offset);
    final List<String> keys = <String>[
      for (int i = 0; i < 7; i += 1) start.addDays(i).iso,
    ];
    return InsightPeriod(
      kind: InsightPeriodKind.weekly,
      periodKey: _isoWeekKey(anchor),
      timezoneId: timezoneId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      dayKeys: keys,
    );
  }

  /// Builds the monthly window containing [anchor], spanning every calendar day
  /// of that month.
  factory InsightPeriod.monthly(
    LocalDate anchor, {
    required String timezoneId,
    required int rangeStartUtc,
    required int rangeEndUtc,
  }) {
    final LocalDate first = anchor.firstDayOfMonth;
    final int days = anchor.daysInMonth;
    final List<String> keys = <String>[
      for (int i = 0; i < days; i += 1) first.addDays(i).iso,
    ];
    return InsightPeriod(
      kind: InsightPeriodKind.monthly,
      periodKey: _monthKey(anchor),
      timezoneId: timezoneId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      dayKeys: keys,
    );
  }

  /// Whether this is a weekly or monthly window.
  final InsightPeriodKind kind;

  /// The stable period key (ISO week `YYYY-Www` or month `YYYY-MM`).
  final String periodKey;

  /// The IANA timezone the window was resolved in, reported alongside every
  /// value so the number is never context-free (R-INSIGHT-002).
  final String timezoneId;

  /// The inclusive start instant of the window in UTC microseconds.
  final int rangeStartUtc;

  /// The exclusive end instant of the window in UTC microseconds.
  final int rangeEndUtc;

  /// The ordered ISO `YYYY-MM-DD` day keys contained by the window.
  final List<String> dayKeys;

  /// The month period key `YYYY-MM`.
  static String _monthKey(LocalDate date) =>
      '${_pad(date.year, 4)}-${_pad(date.month, 2)}';

  /// The ISO-8601 week key `YYYY-Www`: weeks start Monday and week 1 is the week
  /// containing the year's first Thursday. This matches the planner's weekly
  /// record key for the same physical week, so both features agree.
  static String _isoWeekKey(LocalDate date) {
    final LocalDate thursday = date.addDays(4 - date.weekday);
    final int weekYear = thursday.year;
    final int week = ((_dayOfYear(thursday) - 1) ~/ 7) + 1;
    return '${_pad(weekYear, 4)}-W${_pad(week, 2)}';
  }

  static int _dayOfYear(LocalDate date) {
    final LocalDate firstOfYear = LocalDate(date.year, 1, 1);
    int days = 0;
    LocalDate cursor = firstOfYear;
    while (cursor < date) {
      cursor = cursor.addDays(1);
      days += 1;
    }
    return days + 1;
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}
