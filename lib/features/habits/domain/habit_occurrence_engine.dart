import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_occurrence_key.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_schedule_version.dart';

/// Pure deterministic occurrence generator for a [HabitScheduleRule]
/// (R-HABIT-001, R-HABIT-003).
///
/// The engine works entirely in wall-clock local dates: it never touches a
/// clock, timezone database, or persistence, so the same rule always yields the
/// same ordered occurrence keys on every device and run. Dated schedules
/// produce one key per scheduled day; aggregate schedules produce one key per
/// eligible local week/month period.
abstract final class HabitOccurrenceEngine {
  /// Defensive scan cap; real schedules resolve far inside this bound.
  static const int _iterationGuard = 4000000;

  /// The Monday-or-configured week start date of the week containing [date].
  static LocalDate weekStartOf(LocalDate date, int weekStart) {
    final int offset = ((date.weekday - weekStart) % 7 + 7) % 7;
    return date.addDays(-offset);
  }

  /// Whether [date] is a scheduled dated occurrence day of [rule]. Always false
  /// for an aggregate schedule, which has no per-day occurrences.
  static bool isScheduledDate(HabitScheduleRule rule, LocalDate date) {
    if (rule.isAggregate || date < rule.start) {
      return false;
    }
    switch (rule.frequency) {
      case HabitFrequency.daily:
        return _daysBetween(rule.start, date) % rule.interval == 0;
      case HabitFrequency.weekly:
        final LocalDate startWeek = weekStartOf(rule.start, rule.weekStart);
        final LocalDate dateWeek = weekStartOf(date, rule.weekStart);
        final int weekIndex = _daysBetween(startWeek, dateWeek) ~/ 7;
        if (weekIndex < 0 || weekIndex % rule.interval != 0) {
          return false;
        }
        final Set<int> days = rule.weekdays.isEmpty
            ? <int>{rule.start.weekday}
            : rule.weekdays;
        return days.contains(date.weekday);
      case HabitFrequency.monthly:
        final int monthIndex =
            (date.year - rule.start.year) * 12 +
            (date.month - rule.start.month);
        if (monthIndex < 0 || monthIndex % rule.interval != 0) {
          return false;
        }
        final Set<int> days = rule.monthDays.isEmpty
            ? <int>{rule.start.day}
            : rule.monthDays;
        return days.contains(date.day);
    }
  }

  /// Whether the aggregate period anchored at [periodAnchor] is an eligible
  /// period of [rule] (on-interval from the start period). Always false for a
  /// dated schedule.
  static bool isEligiblePeriod(HabitScheduleRule rule, LocalDate periodAnchor) {
    if (!rule.isAggregate) {
      return false;
    }
    switch (rule.frequency) {
      case HabitFrequency.weekly:
        final LocalDate startWeek = weekStartOf(rule.start, rule.weekStart);
        final LocalDate anchorWeek = weekStartOf(periodAnchor, rule.weekStart);
        if (anchorWeek < startWeek) {
          return false;
        }
        final int weekIndex = _daysBetween(startWeek, anchorWeek) ~/ 7;
        return weekIndex % rule.interval == 0;
      case HabitFrequency.monthly:
        final LocalDate startMonth = rule.start.firstDayOfMonth;
        final LocalDate anchorMonth = periodAnchor.firstDayOfMonth;
        if (anchorMonth < startMonth) {
          return false;
        }
        final int monthIndex =
            (anchorMonth.year - startMonth.year) * 12 +
            (anchorMonth.month - startMonth.month);
        return monthIndex % rule.interval == 0;
      case HabitFrequency.daily:
        return false;
    }
  }

  /// The occurrence key that [date] falls into for [rule]. For a dated schedule
  /// this is the dated key for [date]; for an aggregate schedule it is the
  /// enclosing week/month key. Returns null when [date] precedes the schedule
  /// or is not a scheduled dated day.
  static HabitOccurrenceKey? keyFor(HabitScheduleRule rule, LocalDate date) {
    if (date < rule.start) {
      return null;
    }
    if (!rule.isAggregate) {
      return isScheduledDate(rule, date)
          ? HabitOccurrenceKey.dated(date)
          : null;
    }
    switch (rule.frequency) {
      case HabitFrequency.weekly:
        final LocalDate anchor = weekStartOf(date, rule.weekStart);
        return isEligiblePeriod(rule, anchor)
            ? HabitOccurrenceKey.week(anchor)
            : null;
      case HabitFrequency.monthly:
        return isEligiblePeriod(rule, date)
            ? HabitOccurrenceKey.month(date)
            : null;
      case HabitFrequency.daily:
        return null;
    }
  }

  /// Ordered occurrence keys of [rule] whose anchor falls within the inclusive
  /// `[from, to]` local-date window.
  static List<HabitOccurrenceKey> keysBetween(
    HabitScheduleRule rule,
    LocalDate from,
    LocalDate to,
  ) {
    if (to < from) {
      return const <HabitOccurrenceKey>[];
    }
    final List<HabitOccurrenceKey> result = <HabitOccurrenceKey>[];
    if (!rule.isAggregate) {
      LocalDate cursor = from < rule.start ? rule.start : from;
      int iterations = 0;
      while (cursor <= to && iterations < _iterationGuard) {
        iterations += 1;
        if (isScheduledDate(rule, cursor)) {
          result.add(HabitOccurrenceKey.dated(cursor));
        }
        cursor = cursor.addDays(1);
      }
      return result;
    }
    switch (rule.frequency) {
      case HabitFrequency.weekly:
        LocalDate cursor = weekStartOf(
          from < rule.start ? rule.start : from,
          rule.weekStart,
        );
        int iterations = 0;
        while (cursor <= to && iterations < _iterationGuard) {
          iterations += 1;
          if (isEligiblePeriod(rule, cursor)) {
            result.add(HabitOccurrenceKey.week(cursor));
          }
          cursor = cursor.addDays(7);
        }
        return result;
      case HabitFrequency.monthly:
        LocalDate cursor =
            (from < rule.start ? rule.start : from).firstDayOfMonth;
        int iterations = 0;
        while (cursor <= to && iterations < _iterationGuard) {
          iterations += 1;
          if (isEligiblePeriod(rule, cursor)) {
            result.add(HabitOccurrenceKey.month(cursor));
          }
          cursor = cursor.addMonths(1);
        }
        return result;
      case HabitFrequency.daily:
        return result;
    }
  }

  /// The first occurrence key of [rule] on or after its start.
  static HabitOccurrenceKey? first(HabitScheduleRule rule) {
    final List<HabitOccurrenceKey> keys = keysBetween(
      rule,
      rule.start,
      rule.start.addDays(rule.isAggregate ? 800 : 800),
    );
    return keys.isEmpty ? null : keys.first;
  }

  /// The first occurrence key a [version] governs (on or after its effective
  /// key and strictly before its close bound), or null when it has none.
  static HabitOccurrenceKey? firstForVersion(HabitScheduleVersion version) {
    final List<HabitOccurrenceKey> keys = keysForVersion(version, limit: 1);
    return keys.isEmpty ? null : keys.first;
  }

  /// Up to [limit] occurrence keys a [version] governs: anchor on or after its
  /// effective key and strictly before its close bound.
  static List<HabitOccurrenceKey> keysForVersion(
    HabitScheduleVersion version, {
    required int limit,
  }) {
    if (limit <= 0) {
      return const <HabitOccurrenceKey>[];
    }
    final LocalDate? bound = version.exclusiveUpperBound;
    final LocalDate windowEnd =
        (bound ?? version.effectiveOccurrenceKey.addYears(3));
    final List<HabitOccurrenceKey> keys = keysBetween(
      version.rule,
      version.effectiveOccurrenceKey,
      windowEnd,
    );
    final List<HabitOccurrenceKey> result = <HabitOccurrenceKey>[];
    for (final HabitOccurrenceKey key in keys) {
      if (key.anchor < version.effectiveOccurrenceKey) {
        continue;
      }
      if (bound != null && key.anchor >= bound) {
        break;
      }
      result.add(key);
      if (result.length >= limit) {
        break;
      }
    }
    return result;
  }

  /// The next occurrence key a [version] governs strictly after [afterKey], or
  /// null when the version has no further occurrence.
  static HabitOccurrenceKey? nextForVersion(
    HabitScheduleVersion version,
    HabitOccurrenceKey afterKey,
  ) {
    final LocalDate? bound = version.exclusiveUpperBound;
    final LocalDate windowEnd = bound ?? afterKey.anchor.addYears(3);
    final List<HabitOccurrenceKey> keys = keysBetween(
      version.rule,
      afterKey.anchor,
      windowEnd,
    );
    for (final HabitOccurrenceKey key in keys) {
      if (key <= afterKey) {
        continue;
      }
      if (bound != null && key.anchor >= bound) {
        return null;
      }
      return key;
    }
    return null;
  }

  static int _daysBetween(LocalDate a, LocalDate b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}
