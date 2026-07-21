import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_schedule_version.dart';

/// Immutable schedule-version split and version-scoped occurrence policies.
///
/// **Validates: Requirements R-TASK-006, R-TASK-007**
void main() {
  RecurrenceScheduleVersion baseVersion() => RecurrenceScheduleVersion(
    id: 'v1',
    seriesId: 's1',
    version: 1,
    effectiveOccurrenceKey: LocalDate(2024, 6, 1),
    rule: RecurrenceRule(
      frequency: RecurrenceFrequency.daily,
      start: LocalDate(2024, 6, 1),
      timezoneId: 'Etc/UTC',
    ),
  );

  group('split (this and future)', () {
    test('closes the predecessor and anchors a successor', () {
      final RecurrenceScheduleVersion current = baseVersion();
      final RecurrenceSplit split = RecurrencePolicies.split(
        current: current,
        effectiveKey: LocalDate(2024, 6, 5),
        newRule: RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          start: LocalDate(2024, 6, 5),
          timezoneId: 'Etc/UTC',
        ),
        successorId: 'v2',
      );

      expect(split.closed.closedAtOccurrenceKey, LocalDate(2024, 6, 5));
      expect(split.closed.isClosed, isTrue);
      expect(split.successor.version, 2);
      expect(split.successor.predecessorId, 'v1');
      expect(split.successor.effectiveOccurrenceKey, LocalDate(2024, 6, 5));
    });

    test('the closed version stops generating at the effective key', () {
      final RecurrenceScheduleVersion current = baseVersion();
      final RecurrenceSplit split = RecurrencePolicies.split(
        current: current,
        effectiveKey: LocalDate(2024, 6, 5),
        newRule: current.rule,
        successorId: 'v2',
      );
      final List<LocalDate> closedKeys =
          RecurrencePolicies.occurrencesForVersion(split.closed, limit: 100);
      // Daily from Jun 1, closed at Jun 5 → Jun 1..Jun 4 only.
      expect(closedKeys.map((LocalDate d) => d.iso), <String>[
        '2024-06-01',
        '2024-06-02',
        '2024-06-03',
        '2024-06-04',
      ]);
    });

    test('rejects an effective key before the version', () {
      expect(
        () => RecurrencePolicies.split(
          current: baseVersion(),
          effectiveKey: LocalDate(2024, 5, 30),
          newRule: baseVersion().rule,
          successorId: 'v2',
        ),
        throwsFormatException,
      );
    });

    test('rejects splitting an already-closed version', () {
      final RecurrenceScheduleVersion closed = baseVersion().close(
        LocalDate(2024, 6, 10),
      );
      expect(
        () => RecurrencePolicies.split(
          current: closed,
          effectiveKey: LocalDate(2024, 6, 5),
          newRule: closed.rule,
          successorId: 'v2',
        ),
        throwsStateError,
      );
    });
  });

  group('nextForVersion respects the close bound', () {
    test('does not cross into the successor range', () {
      final RecurrenceScheduleVersion closed = baseVersion().close(
        LocalDate(2024, 6, 3),
      );
      expect(
        RecurrencePolicies.nextForVersion(closed, LocalDate(2024, 6, 1)),
        LocalDate(2024, 6, 2),
      );
      // Jun 2 -> next would be Jun 3, but that belongs to the successor.
      expect(
        RecurrencePolicies.nextForVersion(closed, LocalDate(2024, 6, 2)),
        isNull,
      );
    });
  });
}
