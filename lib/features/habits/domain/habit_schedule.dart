import 'package:forge/core/domain/local_date.dart';

/// The cadence family of a habit schedule (R-HABIT-001).
enum HabitFrequency {
  /// Every N days; produces one dated occurrence per scheduled day.
  daily('daily'),

  /// Selected weekdays (dated) or a weekly aggregate period, depending on
  /// [HabitScheduleKind].
  weekly('weekly'),

  /// Selected month days (dated) or a monthly aggregate period, depending on
  /// [HabitScheduleKind].
  monthly('monthly');

  const HabitFrequency(this.wire);

  final String wire;

  static HabitFrequency fromWire(String wire) {
    for (final HabitFrequency freq in HabitFrequency.values) {
      if (freq.wire == wire) {
        return freq;
      }
    }
    throw FormatException('Unknown habit frequency: $wire');
  }
}

/// Whether a schedule produces dated occurrences (one per scheduled day) or
/// aggregate occurrences keyed by local week/month with incremental check-ins
/// (R-HABIT-001, R-HABIT-003).
enum HabitScheduleKind {
  /// One occurrence per scheduled local date (daily and selected-weekday
  /// schedules, and monthly dated schedules).
  dated('dated'),

  /// One aggregate occurrence per local week/month period.
  aggregate('aggregate');

  const HabitScheduleKind(this.wire);

  final String wire;

  static HabitScheduleKind fromWire(String wire) {
    for (final HabitScheduleKind kind in HabitScheduleKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown habit schedule kind: $wire');
  }
}

/// The wall-clock cadence rule of a habit schedule version.
///
/// The rule is a pure, immutable value with no persistence or platform
/// dependency; it validates its own invariants at construction. Occurrence
/// keys derived from it are deterministic local dates or `week_start_date`/
/// `month_key` strings — never wall-clock instants — so the same rule yields
/// the same keys on every device and run (R-HABIT-003). All conversion of a
/// reminder time to an absolute instant is delegated elsewhere; reminder
/// weekdays/times never create extra eligible occurrences (R-HABIT-001).
final class HabitScheduleRule {
  HabitScheduleRule({
    required this.frequency,
    required this.scheduleKind,
    required this.start,
    required this.timezoneId,
    this.interval = 1,
    Set<int>? weekdays,
    Set<int>? monthDays,
    this.weekStart = DateTime.monday,
  }) : weekdays = weekdays == null
           ? const <int>{}
           : Set<int>.unmodifiable(weekdays),
       monthDays = monthDays == null
           ? const <int>{}
           : Set<int>.unmodifiable(monthDays) {
    if (interval < 1) {
      throw FormatException('Habit interval must be >= 1: $interval');
    }
    if (timezoneId.isEmpty) {
      throw const FormatException('A habit schedule requires a timezone.');
    }
    if (weekStart < DateTime.monday || weekStart > DateTime.sunday) {
      throw FormatException(
        'week_start must be an ISO weekday 1..7: $weekStart',
      );
    }
    for (final int weekday in this.weekdays) {
      if (weekday < DateTime.monday || weekday > DateTime.sunday) {
        throw FormatException('Weekday must be an ISO weekday 1..7: $weekday');
      }
    }
    for (final int day in this.monthDays) {
      if (day < 1 || day > 31) {
        throw FormatException('Month day must be 1..31: $day');
      }
    }
    // Weekdays only make sense for a dated weekly (selected-weekday) schedule.
    if (this.weekdays.isNotEmpty &&
        !(frequency == HabitFrequency.weekly &&
            scheduleKind == HabitScheduleKind.dated)) {
      throw const FormatException(
        'Selected weekdays are only valid for a dated weekly schedule.',
      );
    }
    // Month days only make sense for a dated monthly schedule.
    if (this.monthDays.isNotEmpty &&
        !(frequency == HabitFrequency.monthly &&
            scheduleKind == HabitScheduleKind.dated)) {
      throw const FormatException(
        'Selected month days are only valid for a dated monthly schedule.',
      );
    }
  }

  final HabitFrequency frequency;
  final HabitScheduleKind scheduleKind;

  /// The anchor local date the schedule starts on.
  final LocalDate start;

  /// IANA timezone the schedule is interpreted in (R-GEN-004).
  final String timezoneId;

  /// Repetition interval (every N units of [frequency]) for dated daily
  /// schedules and for aggregate week/month period spacing.
  final int interval;

  /// Selected ISO weekdays (1..7) for a dated weekly schedule; empty otherwise.
  final Set<int> weekdays;

  /// Selected month days (1..31) for a dated monthly schedule; empty otherwise.
  final Set<int> monthDays;

  /// ISO weekday the local week begins on for aggregate weekly keys and for
  /// selected-weekday interval math (default Monday).
  final int weekStart;

  /// Whether this rule produces aggregate week/month occurrences.
  bool get isAggregate => scheduleKind == HabitScheduleKind.aggregate;
}
