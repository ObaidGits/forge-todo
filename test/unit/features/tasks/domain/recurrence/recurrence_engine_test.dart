import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_engine.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_weekday.dart';

/// Deterministic occurrence-generation tests for the pure recurrence engine.
///
/// **Validates: Requirements R-TASK-005, R-TASK-006**
void main() {
  List<String> keys(List<LocalDate> dates) =>
      dates.map((LocalDate d) => d.iso).toList();

  group('daily frequency', () {
    test('every day from the start', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 3)), <String>[
        '2024-06-01',
        '2024-06-02',
        '2024-06-03',
      ]);
    });

    test('interval skips days', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        interval: 3,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 3)), <String>[
        '2024-06-01',
        '2024-06-04',
        '2024-06-07',
      ]);
    });
  });

  group('weekly frequency', () {
    test('defaults to the start weekday', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.weekly,
        start: LocalDate(2024, 6, 3), // Monday
        timezoneId: 'Etc/UTC',
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 3)), <String>[
        '2024-06-03',
        '2024-06-10',
        '2024-06-17',
      ]);
    });

    test('selected weekdays within an interval', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.weekly,
        interval: 2,
        start: LocalDate(2024, 6, 3), // Monday
        timezoneId: 'Etc/UTC',
        byWeekdays: <RecurrenceWeekday>{
          RecurrenceWeekday.monday,
          RecurrenceWeekday.wednesday,
        },
      );
      // Week of Jun 3 (index 0): Mon 3, Wed 5. Week of Jun 10 (index 1) is
      // skipped by interval 2. Week of Jun 17 (index 2): Mon 17, Wed 19.
      expect(keys(RecurrenceEngine.take(rule, limit: 4)), <String>[
        '2024-06-03',
        '2024-06-05',
        '2024-06-17',
        '2024-06-19',
      ]);
    });
  });

  group('monthly frequency', () {
    test('same day each month', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        start: LocalDate(2024, 1, 15),
        timezoneId: 'Etc/UTC',
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 3)), <String>[
        '2024-01-15',
        '2024-02-15',
        '2024-03-15',
      ]);
    });

    test('BYMONTHDAY 31 skips months without a 31st (RFC skip)', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.monthly,
        start: LocalDate(2024, 1, 31),
        timezoneId: 'Etc/UTC',
        byMonthDays: <int>{31},
      );
      // Feb, Apr, Jun ... lack a 31st and are skipped, not rolled forward.
      expect(keys(RecurrenceEngine.take(rule, limit: 4)), <String>[
        '2024-01-31',
        '2024-03-31',
        '2024-05-31',
        '2024-07-31',
      ]);
    });
  });

  group('yearly frequency', () {
    test('anchors to the start month and day', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.yearly,
        start: LocalDate(2024, 2, 29),
        timezoneId: 'Etc/UTC',
      );
      // Only leap years have Feb 29.
      expect(keys(RecurrenceEngine.take(rule, limit: 2)), <String>[
        '2024-02-29',
        '2028-02-29',
      ]);
    });
  });

  group('bounds', () {
    test('COUNT limits total occurrences', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
        end: RecurrenceEnd.count(3),
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 10)), <String>[
        '2024-06-01',
        '2024-06-02',
        '2024-06-03',
      ]);
      expect(RecurrenceEngine.next(rule, LocalDate(2024, 6, 3)), isNull);
    });

    test('UNTIL bounds by date inclusively', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
        end: RecurrenceEnd.until(LocalDate(2024, 6, 2)),
      );
      expect(keys(RecurrenceEngine.take(rule, limit: 10)), <String>[
        '2024-06-01',
        '2024-06-02',
      ]);
    });
  });

  group('exceptions', () {
    test('excluded dates are removed but still consume COUNT', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
        end: RecurrenceEnd.count(3),
        exceptions: <LocalDate>{LocalDate(2024, 6, 2)},
      );
      // Jun 2 is excluded; COUNT of 3 still stops the raw series at Jun 3.
      expect(keys(RecurrenceEngine.take(rule, limit: 10)), <String>[
        '2024-06-01',
        '2024-06-03',
      ]);
      expect(
        RecurrenceEngine.isOccurrence(rule, LocalDate(2024, 6, 2)),
        isFalse,
      );
    });

    test('next skips excluded occurrences', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
        exceptions: <LocalDate>{LocalDate(2024, 6, 2), LocalDate(2024, 6, 3)},
      );
      expect(
        RecurrenceEngine.next(rule, LocalDate(2024, 6, 1)),
        LocalDate(2024, 6, 4),
      );
    });
  });

  group('next and first', () {
    test('first returns the start when aligned', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.weekly,
        start: LocalDate(2024, 6, 3),
        timezoneId: 'Etc/UTC',
      );
      expect(RecurrenceEngine.first(rule), LocalDate(2024, 6, 3));
    });

    test('between returns occurrences inside an inclusive window', () {
      final RecurrenceRule rule = RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        interval: 2,
        start: LocalDate(2024, 6, 1),
        timezoneId: 'Etc/UTC',
      );
      expect(
        keys(
          RecurrenceEngine.between(
            rule,
            LocalDate(2024, 6, 4),
            LocalDate(2024, 6, 9),
          ),
        ),
        <String>['2024-06-05', '2024-06-07', '2024-06-09'],
      );
    });
  });
}
