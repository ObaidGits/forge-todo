import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit_occurrence_engine.dart';
import 'package:forge/features/habits/domain/habit_occurrence_key.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';

/// Deterministic occurrence keys for dated and aggregate schedules
/// (R-HABIT-001, R-HABIT-003).
void main() {
  HabitScheduleRule daily({int interval = 1}) => HabitScheduleRule(
    frequency: HabitFrequency.daily,
    scheduleKind: HabitScheduleKind.dated,
    start: LocalDate(2024, 6, 3), // a Monday
    timezoneId: 'Etc/UTC',
    interval: interval,
  );

  group('dated daily schedules', () {
    test('produce one key per day at interval 1', () {
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        daily(),
        LocalDate(2024, 6, 3),
        LocalDate(2024, 6, 6),
      );
      expect(keys.map((HabitOccurrenceKey k) => k.value), <String>[
        '2024-06-03',
        '2024-06-04',
        '2024-06-05',
        '2024-06-06',
      ]);
    });

    test('honor an interval', () {
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        daily(interval: 2),
        LocalDate(2024, 6, 3),
        LocalDate(2024, 6, 8),
      );
      expect(keys.map((HabitOccurrenceKey k) => k.value), <String>[
        '2024-06-03',
        '2024-06-05',
        '2024-06-07',
      ]);
    });
  });

  group('dated selected-weekday schedules', () {
    test('produce keys only on selected weekdays', () {
      final HabitScheduleRule rule = HabitScheduleRule(
        frequency: HabitFrequency.weekly,
        scheduleKind: HabitScheduleKind.dated,
        start: LocalDate(2024, 6, 3), // Monday
        timezoneId: 'Etc/UTC',
        weekdays: <int>{DateTime.monday, DateTime.wednesday, DateTime.friday},
      );
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        rule,
        LocalDate(2024, 6, 3),
        LocalDate(2024, 6, 9),
      );
      expect(keys.map((HabitOccurrenceKey k) => k.value), <String>[
        '2024-06-03',
        '2024-06-05',
        '2024-06-07',
      ]);
    });
  });

  group('aggregate weekly schedules', () {
    test('produce one week_start key per week', () {
      final HabitScheduleRule rule = HabitScheduleRule(
        frequency: HabitFrequency.weekly,
        scheduleKind: HabitScheduleKind.aggregate,
        start: LocalDate(2024, 6, 5), // a Wednesday
        timezoneId: 'Etc/UTC',
      );
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        rule,
        LocalDate(2024, 6, 5),
        LocalDate(2024, 6, 18),
      );
      // Weeks anchored on Monday: 2024-06-03, 2024-06-10, 2024-06-17.
      expect(keys.map((HabitOccurrenceKey k) => k.value), <String>[
        '2024-06-03',
        '2024-06-10',
        '2024-06-17',
      ]);
      // Any date in a week maps to the same week key.
      expect(
        HabitOccurrenceEngine.keyFor(rule, LocalDate(2024, 6, 8))!.value,
        '2024-06-03',
      );
    });
  });

  group('aggregate monthly schedules', () {
    test('produce one YYYY-MM key per month', () {
      final HabitScheduleRule rule = HabitScheduleRule(
        frequency: HabitFrequency.monthly,
        scheduleKind: HabitScheduleKind.aggregate,
        start: LocalDate(2024, 6, 15),
        timezoneId: 'Etc/UTC',
      );
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        rule,
        LocalDate(2024, 6, 15),
        LocalDate(2024, 8, 2),
      );
      expect(keys.map((HabitOccurrenceKey k) => k.value), <String>[
        '2024-06',
        '2024-07',
        '2024-08',
      ]);
      expect(
        HabitOccurrenceEngine.keyFor(rule, LocalDate(2024, 7, 30))!.value,
        '2024-07',
      );
    });
  });

  test(
    'reminder-time weekdays do not add occurrences (dated daily is daily)',
    () {
      // A daily schedule ignores weekday selections entirely; the engine has no
      // notion of reminder weekdays, so no extra occurrences can appear.
      final List<HabitOccurrenceKey> keys = HabitOccurrenceEngine.keysBetween(
        daily(),
        LocalDate(2024, 6, 3),
        LocalDate(2024, 6, 5),
      );
      expect(keys.length, 3);
    },
  );

  group('determinism (property based)', () {
    test('keysBetween is stable and strictly increasing across seeds', () {
      final Random random = Random(0x5EED);
      for (int iteration = 0; iteration < 500; iteration++) {
        final HabitScheduleKind kind = random.nextBool()
            ? HabitScheduleKind.dated
            : HabitScheduleKind.aggregate;
        final HabitFrequency frequency = kind == HabitScheduleKind.aggregate
            ? (random.nextBool()
                  ? HabitFrequency.weekly
                  : HabitFrequency.monthly)
            : HabitFrequency.values[random.nextInt(
                HabitFrequency.values.length,
              )];
        final LocalDate start = LocalDate(
          2024,
          1 + random.nextInt(12),
          1 + random.nextInt(28),
        );
        final HabitScheduleRule rule = HabitScheduleRule(
          frequency: frequency,
          scheduleKind: kind,
          start: start,
          timezoneId: 'Etc/UTC',
          interval: 1 + random.nextInt(3),
          weekdays:
              (kind == HabitScheduleKind.dated &&
                  frequency == HabitFrequency.weekly)
              ? <int>{1 + random.nextInt(7)}
              : const <int>{},
          monthDays:
              (kind == HabitScheduleKind.dated &&
                  frequency == HabitFrequency.monthly)
              ? <int>{1 + random.nextInt(28)}
              : const <int>{},
        );
        final LocalDate to = start.addDays(120);
        final List<HabitOccurrenceKey> first =
            HabitOccurrenceEngine.keysBetween(rule, start, to);
        final List<HabitOccurrenceKey> second =
            HabitOccurrenceEngine.keysBetween(rule, start, to);
        // Same inputs -> identical ordered keys.
        expect(
          first.map((HabitOccurrenceKey k) => k.value),
          second.map((HabitOccurrenceKey k) => k.value),
        );
        // Strictly increasing anchors and unique keys.
        for (int i = 1; i < first.length; i++) {
          expect(first[i] > first[i - 1], isTrue);
        }
        expect(
          first.map((HabitOccurrenceKey k) => k.value).toSet().length,
          first.length,
        );
      }
    });
  });
}
