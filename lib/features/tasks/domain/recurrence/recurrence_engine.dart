import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';

/// Pure deterministic occurrence generator for a [RecurrenceRule] (R-TASK-005,
/// R-TASK-006).
///
/// The engine works entirely in wall-clock local dates: it never touches a
/// clock, timezone database, or persistence, so the same rule always yields the
/// same ordered occurrence keys on every device and run. Time-of-day to UTC
/// instant conversion (and therefore all DST behavior) is delegated elsewhere
/// to a `TimeZoneResolver`.
///
/// Bound semantics follow RFC-5545: a `COUNT` limit counts raw pattern
/// occurrences *including* excluded (`EXDATE`) dates, while `UNTIL` bounds by
/// date. Exceptions are removed from the visible result but still consume a
/// `COUNT` slot.
abstract final class RecurrenceEngine {
  /// A defensive cap on day-by-day scanning. Real rules always find their next
  /// occurrence far inside this bound (at most a few years for yearly Feb-29
  /// style rules); the cap only prevents a runaway loop from a logic error.
  static const int _iterationGuard = 4000000; // ~10958 years of days

  /// Whether [date] is a real occurrence of [rule]: it fits the pattern, is on
  /// or after the start, is within the rule's bound, and is not excluded.
  static bool isOccurrence(RecurrenceRule rule, LocalDate date) {
    if (rule.exceptions.contains(date)) {
      return false;
    }
    if (!_matchesPattern(rule, date)) {
      return false;
    }
    final RecurrenceEnd end = rule.end;
    if (end is UntilDate) {
      return date <= end.date;
    }
    if (end is CountLimit) {
      // Count the raw pattern occurrences up to and including [date].
      int seen = 0;
      for (final LocalDate raw in _rawOccurrences(rule)) {
        seen += 1;
        if (raw == date) {
          return seen <= end.count;
        }
        if (raw > date) {
          return false;
        }
      }
      return false;
    }
    return true;
  }

  /// The first real occurrence of [rule], or null when the rule generates none
  /// (only possible for a fully-excluded bounded rule).
  static LocalDate? first(RecurrenceRule rule) {
    for (final LocalDate raw in _rawOccurrences(rule)) {
      if (!rule.exceptions.contains(raw)) {
        return raw;
      }
    }
    return null;
  }

  /// The first real occurrence strictly after [after], or null when the series
  /// has ended.
  static LocalDate? next(RecurrenceRule rule, LocalDate after) {
    for (final LocalDate raw in _rawOccurrences(rule)) {
      if (raw <= after) {
        continue;
      }
      if (!rule.exceptions.contains(raw)) {
        return raw;
      }
    }
    return null;
  }

  /// Up to [limit] real occurrences on or after [from] (defaults to the rule
  /// start). Used to materialize a bounded horizon of future occurrences.
  static List<LocalDate> take(
    RecurrenceRule rule, {
    required int limit,
    LocalDate? from,
  }) {
    if (limit <= 0) {
      return const <LocalDate>[];
    }
    final LocalDate floor = from ?? rule.start;
    final List<LocalDate> result = <LocalDate>[];
    for (final LocalDate raw in _rawOccurrences(rule)) {
      if (raw < floor) {
        continue;
      }
      if (rule.exceptions.contains(raw)) {
        continue;
      }
      result.add(raw);
      if (result.length >= limit) {
        break;
      }
    }
    return result;
  }

  /// All real occurrences within the inclusive `[from, to]` local-date window.
  static List<LocalDate> between(
    RecurrenceRule rule,
    LocalDate from,
    LocalDate to,
  ) {
    if (to < from) {
      return const <LocalDate>[];
    }
    final List<LocalDate> result = <LocalDate>[];
    for (final LocalDate raw in _rawOccurrences(rule)) {
      if (raw > to) {
        break;
      }
      if (raw < from || rule.exceptions.contains(raw)) {
        continue;
      }
      result.add(raw);
    }
    return result;
  }

  /// Lazily yields the ordered *raw* pattern dates (before exception removal),
  /// honoring `COUNT`/`UNTIL` so the generator is finite for a bounded rule and
  /// otherwise lazily infinite.
  static Iterable<LocalDate> _rawOccurrences(RecurrenceRule rule) sync* {
    final RecurrenceEnd end = rule.end;
    final LocalDate? until = end is UntilDate ? end.date : null;
    final int? count = end is CountLimit ? end.count : null;

    LocalDate cursor = rule.start;
    int generated = 0;
    int iterations = 0;
    while (iterations < _iterationGuard) {
      iterations += 1;
      if (count != null && generated >= count) {
        return;
      }
      if (until != null && cursor > until) {
        return;
      }
      if (_matchesPattern(rule, cursor)) {
        generated += 1;
        yield cursor;
      }
      cursor = cursor.addDays(1);
    }
  }

  /// Whether [date] fits the rule's frequency/interval/by-field pattern,
  /// ignoring exceptions and bounds. Skipped `BYMONTHDAY` values (a day that
  /// does not exist in a month) never match, matching RFC-5545 skip semantics.
  static bool _matchesPattern(RecurrenceRule rule, LocalDate date) {
    if (date < rule.start) {
      return false;
    }
    switch (rule.frequency) {
      case RecurrenceFrequency.daily:
        if (_daysBetween(rule.start, date) % rule.interval != 0) {
          return false;
        }
        if (rule.byWeekdays.isEmpty) {
          return true;
        }
        return rule.byWeekdays.any((w) => w.isoWeekday == date.weekday);
      case RecurrenceFrequency.weekly:
        final int weekIndex = _weeksBetween(rule.start, date);
        if (weekIndex < 0 || weekIndex % rule.interval != 0) {
          return false;
        }
        if (rule.byWeekdays.isEmpty) {
          return date.weekday == rule.start.weekday;
        }
        return rule.byWeekdays.any((w) => w.isoWeekday == date.weekday);
      case RecurrenceFrequency.monthly:
        final int monthIndex =
            (date.year - rule.start.year) * 12 +
            (date.month - rule.start.month);
        if (monthIndex < 0 || monthIndex % rule.interval != 0) {
          return false;
        }
        if (rule.byMonthDays.isEmpty) {
          return date.day == rule.start.day;
        }
        return rule.byMonthDays.contains(date.day);
      case RecurrenceFrequency.yearly:
        final int yearIndex = date.year - rule.start.year;
        if (yearIndex < 0 || yearIndex % rule.interval != 0) {
          return false;
        }
        if (date.month != rule.start.month) {
          return false;
        }
        if (rule.byMonthDays.isEmpty) {
          return date.day == rule.start.day;
        }
        return rule.byMonthDays.contains(date.day);
    }
  }

  static int _daysBetween(LocalDate a, LocalDate b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// Whole weeks between the Monday-anchored weeks of [a] and [b].
  static int _weeksBetween(LocalDate a, LocalDate b) {
    final LocalDate mondayA = a.addDays(1 - a.weekday);
    final LocalDate mondayB = b.addDays(1 - b.weekday);
    return _daysBetween(mondayA, mondayB) ~/ 7;
  }
}
