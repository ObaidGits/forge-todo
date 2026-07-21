import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notifications/domain/reminder.dart';

/// The reminder owner-type / category vocabulary, including the V1 `workout`
/// owner (task 10.5, R-NOTIFY-001).
///
/// **Validates: Requirements R-NOTIFY-001**
///
/// Evidence: [TEST-UNIT-REMINDER-OWNER][V1][TASK-10.5]
void main() {
  group('reminder owner types (R-NOTIFY-001)', () {
    test('include workout alongside the MVP owners', () {
      expect(ReminderOwnerType.values, <ReminderOwnerType>[
        ReminderOwnerType.task,
        ReminderOwnerType.habit,
        ReminderOwnerType.study,
        ReminderOwnerType.deadline,
        ReminderOwnerType.workout,
      ]);
    });

    test('workout owner round-trips through its stable wire string', () {
      expect(ReminderOwnerType.workout.wire, 'workout');
      expect(ReminderOwnerType.fromWire('workout'), ReminderOwnerType.workout);
    });

    test('an unknown owner wire string is rejected', () {
      expect(() => ReminderOwnerType.fromWire('gizmo'), throwsFormatException);
    });
  });

  group('reminder categories (R-NOTIFY-006)', () {
    test('map the workout owner to its own workout category', () {
      expect(
        ReminderCategory.forOwner(ReminderOwnerType.workout),
        ReminderCategory.workout,
      );
      expect(ReminderCategory.workout.wire, 'workout');
      expect(ReminderCategory.fromWire('workout'), ReminderCategory.workout);
    });

    test('every owner type maps to a category (exhaustive)', () {
      for (final ReminderOwnerType owner in ReminderOwnerType.values) {
        // Must not throw for any owner (the switch is exhaustive).
        expect(ReminderCategory.forOwner(owner), isA<ReminderCategory>());
      }
    });
  });
}
