import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';

/// Pure calendar-primitive tests underpinning deterministic recurrence math.
///
/// **Validates: Requirements R-GEN-004**
void main() {
  group('LocalDate parsing and validation', () {
    test('parses a valid ISO date', () {
      final LocalDate date = LocalDate.parse('2024-02-29');
      expect(date.year, 2024);
      expect(date.month, 2);
      expect(date.day, 29);
      expect(date.iso, '2024-02-29');
    });

    test('rejects Feb 29 in a non-leap year', () {
      expect(() => LocalDate(2023, 2, 29), throwsFormatException);
    });

    test('rejects a malformed string', () {
      expect(() => LocalDate.parse('2024/02/29'), throwsFormatException);
      expect(() => LocalDate.parse('2024-13-01'), throwsFormatException);
    });
  });

  group('LocalDate arithmetic', () {
    test('addDays crosses month and year boundaries', () {
      expect(LocalDate(2024, 1, 31).addDays(1), LocalDate(2024, 2, 1));
      expect(LocalDate(2024, 12, 31).addDays(1), LocalDate(2025, 1, 1));
      expect(LocalDate(2024, 3, 1).addDays(-1), LocalDate(2024, 2, 29));
    });

    test('addMonths clamps to the last valid day', () {
      expect(LocalDate(2024, 1, 31).addMonths(1), LocalDate(2024, 2, 29));
      expect(LocalDate(2023, 1, 31).addMonths(1), LocalDate(2023, 2, 28));
      expect(LocalDate(2024, 1, 31).addMonths(3), LocalDate(2024, 4, 30));
    });

    test('addYears clamps Feb 29 to Feb 28', () {
      expect(LocalDate(2024, 2, 29).addYears(1), LocalDate(2025, 2, 28));
      expect(LocalDate(2024, 2, 29).addYears(4), LocalDate(2028, 2, 29));
    });

    test('weekday is ISO Monday=1..Sunday=7', () {
      expect(LocalDate(2024, 6, 3).weekday, 1); // Monday
      expect(LocalDate(2024, 6, 9).weekday, 7); // Sunday
    });

    test('monthHasDay reflects skip semantics', () {
      expect(LocalDate(2024, 2, 1).monthHasDay(31), isFalse);
      expect(LocalDate(2024, 1, 1).monthHasDay(31), isTrue);
    });
  });

  group('ordering', () {
    test('compares chronologically', () {
      expect(LocalDate(2024, 1, 1) < LocalDate(2024, 1, 2), isTrue);
      expect(LocalDate(2024, 2, 1) > LocalDate(2024, 1, 31), isTrue);
      expect(LocalDate(2024, 1, 1) == LocalDate(2024, 1, 1), isTrue);
    });
  });

  group('LocalTime', () {
    test('round-trips seconds of day', () {
      final LocalTime time = LocalTime(9, 30, 15);
      expect(time.secondsOfDay, 9 * 3600 + 30 * 60 + 15);
      expect(LocalTime.fromSecondsOfDay(time.secondsOfDay), time);
    });

    test('rejects out-of-range components', () {
      expect(() => LocalTime(24, 0), throwsFormatException);
      expect(() => LocalTime(0, 60), throwsFormatException);
    });

    test('parses HH:MM and HH:MM:SS', () {
      expect(LocalTime.parse('07:05'), LocalTime(7, 5));
      expect(LocalTime.parse('07:05:09'), LocalTime(7, 5, 9));
    });
  });

  group('LocalDateTime', () {
    test('renders an ISO wall-clock string', () {
      final LocalDateTime dt = LocalDateTime(
        LocalDate(2024, 6, 1),
        LocalTime(9, 0),
      );
      expect(dt.iso, '2024-06-01T09:00:00');
    });
  });
}
