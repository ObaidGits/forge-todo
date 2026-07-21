import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/domain/habit_checkin.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';
import 'package:forge/features/habits/domain/habit_projection_policy.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// Projection derivation from non-superseded check-ins (R-HABIT-002,
/// R-HABIT-003).
void main() {
  group('boolean targets', () {
    test('complete on an explicit true observation', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.boolean(),
        observations: const <HabitObservation>[HabitObservation.booleanTrue()],
        isClosed: false,
      );
      expect(p.status, HabitOccurrenceStatus.completed);
    });

    test('are open before close and missed once closed without a true', () {
      expect(
        HabitProjectionPolicy.project(
          target: HabitTarget.boolean(),
          observations: const <HabitObservation>[],
          isClosed: false,
        ).status,
        HabitOccurrenceStatus.open,
      );
      expect(
        HabitProjectionPolicy.project(
          target: HabitTarget.boolean(),
          observations: const <HabitObservation>[],
          isClosed: true,
        ).status,
        HabitOccurrenceStatus.missed,
      );
    });
  });

  group('numeric targets', () {
    test('complete when the normalized total meets the target', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.count(3),
        observations: const <HabitObservation>[
          HabitObservation.value(1),
          HabitObservation.value(2),
        ],
        isClosed: false,
      );
      expect(p.normalizedTotal, 3);
      expect(p.status, HabitOccurrenceStatus.completed);
    });

    test('accumulate partial totals and stay open until met', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.duration(
          targetSeconds: 1800,
          displayUnit: 'minutes',
        ),
        observations: const <HabitObservation>[HabitObservation.value(600)],
        isClosed: false,
      );
      expect(p.normalizedTotal, 600);
      expect(p.status, HabitOccurrenceStatus.open);
    });

    test('are missed when closed below the target', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.count(5),
        observations: const <HabitObservation>[HabitObservation.value(2)],
        isClosed: true,
      );
      expect(p.status, HabitOccurrenceStatus.missed);
    });
  });

  group('abstinence targets', () {
    test('become missed on the first non-superseded violation', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.abstinence(),
        observations: const <HabitObservation>[HabitObservation.violation()],
        isClosed: false,
      );
      expect(p.hasViolation, isTrue);
      expect(p.status, HabitOccurrenceStatus.missed);
    });

    test('stay open until the period closes with no violation', () {
      expect(
        HabitProjectionPolicy.project(
          target: HabitTarget.abstinence(),
          observations: const <HabitObservation>[],
          isClosed: false,
        ).status,
        HabitOccurrenceStatus.open,
      );
    });

    test('complete only on close with no violation', () {
      expect(
        HabitProjectionPolicy.project(
          target: HabitTarget.abstinence(),
          observations: const <HabitObservation>[],
          isClosed: true,
        ).status,
        HabitOccurrenceStatus.completed,
      );
    });

    test('remain missed at close when a violation exists', () {
      expect(
        HabitProjectionPolicy.project(
          target: HabitTarget.abstinence(),
          observations: const <HabitObservation>[HabitObservation.violation()],
          isClosed: true,
        ).status,
        HabitOccurrenceStatus.missed,
      );
    });
  });
}
