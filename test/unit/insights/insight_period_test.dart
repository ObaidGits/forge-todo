import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/insights/domain/insight_period.dart';

void main() {
  group('[TEST-INSIGHT-PERIOD-KEYS][V1][TASK-10.4][R-INSIGHT-002] weekly '
      'window', () {
    test('a weekly window spans seven Monday-anchored days', () {
      // 2024-06-05 is a Wednesday; the Monday week starts 2024-06-03.
      final InsightPeriod period = InsightPeriod.weekly(
        LocalDate(2024, 6, 5),
        timezoneId: 'UTC',
        rangeStartUtc: 0,
        rangeEndUtc: 10,
      );
      expect(period.kind, InsightPeriodKind.weekly);
      expect(period.dayKeys.length, 7);
      expect(period.dayKeys.first, '2024-06-03');
      expect(period.dayKeys.last, '2024-06-09');
      // ISO week 23 of 2024.
      expect(period.periodKey, '2024-W23');
    });

    test('a Sunday week start shifts the anchor', () {
      final InsightPeriod period = InsightPeriod.weekly(
        LocalDate(2024, 6, 5),
        timezoneId: 'UTC',
        rangeStartUtc: 0,
        rangeEndUtc: 10,
        weekStart: DateTime.sunday,
      );
      expect(period.dayKeys.first, '2024-06-02');
      expect(period.dayKeys.last, '2024-06-08');
    });
  });

  group('[TEST-INSIGHT-PERIOD-KEYS-MONTH][V1][TASK-10.4][R-INSIGHT-002] '
      'monthly window', () {
    test('a monthly window spans every day of the month', () {
      final InsightPeriod june = InsightPeriod.monthly(
        LocalDate(2024, 6, 15),
        timezoneId: 'UTC',
        rangeStartUtc: 0,
        rangeEndUtc: 10,
      );
      expect(june.kind, InsightPeriodKind.monthly);
      expect(june.periodKey, '2024-06');
      expect(june.dayKeys.length, 30);
      expect(june.dayKeys.first, '2024-06-01');
      expect(june.dayKeys.last, '2024-06-30');
    });

    test('February in a leap year has 29 days', () {
      final InsightPeriod feb = InsightPeriod.monthly(
        LocalDate(2024, 2, 10),
        timezoneId: 'UTC',
        rangeStartUtc: 0,
        rangeEndUtc: 10,
      );
      expect(feb.dayKeys.length, 29);
      expect(feb.dayKeys.last, '2024-02-29');
    });
  });

  group('[TEST-INSIGHT-PERIOD-VALIDATION][V1][TASK-10.4][R-INSIGHT-002] '
      'validation', () {
    test('a descending range is rejected', () {
      expect(
        () => InsightPeriod.weekly(
          LocalDate(2024, 6, 5),
          timezoneId: 'UTC',
          rangeStartUtc: 100,
          rangeEndUtc: 0,
        ),
        throwsFormatException,
      );
    });

    test('an out-of-range week start is rejected', () {
      expect(
        () => InsightPeriod.weekly(
          LocalDate(2024, 6, 5),
          timezoneId: 'UTC',
          rangeStartUtc: 0,
          rangeEndUtc: 10,
          weekStart: 8,
        ),
        throwsFormatException,
      );
    });
  });
}
