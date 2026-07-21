import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_weekday.dart';

/// The documented RFC-5545-compatible recurrence rule Forge supports
/// (R-TASK-005): interval; daily/weekly/monthly/yearly frequency; selected
/// weekdays; month day; end date/count; timezone; and exceptions.
///
/// A rule is a pure, immutable value with no persistence or platform
/// dependency. It validates its own invariants at construction so an illegal
/// rule cannot exist in the domain. All occurrence keys are wall-clock local
/// dates in [timezoneId]; conversion of [timeOfDay] to an absolute instant is
/// delegated to a `TimeZoneResolver` and is never performed here.
final class RecurrenceRule {
  RecurrenceRule({
    required this.frequency,
    required this.start,
    required this.timezoneId,
    this.interval = 1,
    Set<RecurrenceWeekday>? byWeekdays,
    Set<int>? byMonthDays,
    this.timeOfDay,
    this.end = RecurrenceEnd.never,
    Set<LocalDate>? exceptions,
  }) : byWeekdays = byWeekdays == null
           ? const <RecurrenceWeekday>{}
           : Set<RecurrenceWeekday>.unmodifiable(byWeekdays),
       byMonthDays = byMonthDays == null
           ? const <int>{}
           : Set<int>.unmodifiable(byMonthDays),
       exceptions = exceptions == null
           ? const <LocalDate>{}
           : Set<LocalDate>.unmodifiable(exceptions) {
    if (interval < 1) {
      throw FormatException('Recurrence interval must be >= 1: $interval');
    }
    if (timezoneId.isEmpty) {
      throw const FormatException('Recurrence requires a non-empty timezone.');
    }
    for (final int day in this.byMonthDays) {
      if (day < 1 || day > 31) {
        throw FormatException('BYMONTHDAY must be 1..31: $day');
      }
    }
    if (this.byWeekdays.isNotEmpty &&
        frequency != RecurrenceFrequency.weekly &&
        frequency != RecurrenceFrequency.daily) {
      throw const FormatException(
        'BYDAY is only supported for daily/weekly frequency in this subset.',
      );
    }
    if (this.byMonthDays.isNotEmpty &&
        frequency != RecurrenceFrequency.monthly &&
        frequency != RecurrenceFrequency.yearly) {
      throw const FormatException(
        'BYMONTHDAY is only supported for monthly/yearly frequency.',
      );
    }
    final RecurrenceEnd bound = end;
    if (bound is UntilDate && bound.date < start) {
      throw const FormatException('UNTIL must not precede the start date.');
    }
  }

  final RecurrenceFrequency frequency;

  /// The `DTSTART` anchor local date. The first candidate occurrence is on or
  /// after this date.
  final LocalDate start;

  /// IANA timezone the rule is interpreted in (R-GEN-004).
  final String timezoneId;

  /// Repetition interval (every N units of [frequency]).
  final int interval;

  /// Selected weekdays (`BYDAY`). Empty means "the weekday of [start]" for
  /// weekly frequency and "every day" for daily frequency.
  final Set<RecurrenceWeekday> byWeekdays;

  /// Selected month days (`BYMONTHDAY`, 1..31). Empty means "the day of
  /// [start]". A selected day that does not exist in a given month is skipped
  /// (RFC-5545 semantics), never rolled into the next month.
  final Set<int> byMonthDays;

  /// Wall-clock time of day for instant occurrences, or null for floating
  /// date-only occurrences (R-GEN-004: floating all-day dates never shift).
  final LocalTime? timeOfDay;

  /// When the series stops generating occurrences.
  final RecurrenceEnd end;

  /// Excluded occurrence dates (`EXDATE`). Provided by the caller when
  /// evaluating the rule; the persisted schedule version stays immutable and
  /// records exceptions as append-only occurrence events instead.
  final Set<LocalDate> exceptions;

  /// Whether occurrences carry a time of day (and therefore a UTC instant).
  bool get isTimed => timeOfDay != null;

  /// Returns a copy of this rule with [exceptions] replaced. Used to feed the
  /// engine the current exception set gathered from occurrence history without
  /// mutating the immutable schedule version.
  RecurrenceRule withExceptions(Set<LocalDate> exceptions) => RecurrenceRule(
    frequency: frequency,
    start: start,
    timezoneId: timezoneId,
    interval: interval,
    byWeekdays: byWeekdays,
    byMonthDays: byMonthDays,
    timeOfDay: timeOfDay,
    end: end,
    exceptions: exceptions,
  );
}
