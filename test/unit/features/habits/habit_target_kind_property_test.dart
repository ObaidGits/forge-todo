import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/domain/habit_checkin.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';
import 'package:forge/features/habits/domain/habit_projection_policy.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// Wave 6 risk gate — generative target-kind suite (R-HABIT-002, R-HABIT-003).
///
/// The pure projection policy is exercised across randomized non-superseded
/// observation sequences for every target kind: boolean, count, duration,
/// quantity, and abstinence. The properties pin the authoritative per-kind
/// semantics: numeric totals accumulate partial contributions and complete only
/// when the normalized total meets the bound version's target; boolean
/// completes on an explicit true; abstinence follows close-with-no-violation;
/// and a retraction (`correct`) never registers as an abstinence violation, so
/// a cleared violation lets the period complete on close.
///
/// **Validates: Requirements R-HABIT-002, R-HABIT-003**
///
/// Evidence: [TEST-HABIT-KIND-PROP][MVP][TASK-7.6][R-HABIT-002,R-HABIT-003]
void main() {
  // A small palette of positive targets shared by the numeric properties. The
  // canonical duration target stores seconds while preserving a display unit;
  // quantity requires a unit; count is a bare positive integer.
  HabitTarget numericTarget(HabitTargetKind kind, int target) {
    switch (kind) {
      case HabitTargetKind.count:
        return HabitTarget.count(target);
      case HabitTargetKind.duration:
        return HabitTarget.duration(
          targetSeconds: target,
          displayUnit: 'minutes',
        );
      case HabitTargetKind.quantity:
        return HabitTarget.quantity(targetValue: target, unit: 'ml');
      case HabitTargetKind.boolean:
      case HabitTargetKind.abstinence:
        throw ArgumentError('not numeric');
    }
  }

  group(
    '[TEST-HABIT-KIND-PROP][MVP][TASK-7.6][R-HABIT-002,R-HABIT-003] numeric '
    'target-kind projection',
    () {
      test('normalized total is the exact sum of value observations and '
          'completion tracks the target across partial accumulation', () {
        final Random random = Random(0xA11CE);
        const List<HabitTargetKind> numeric = <HabitTargetKind>[
          HabitTargetKind.count,
          HabitTargetKind.duration,
          HabitTargetKind.quantity,
        ];
        for (int iteration = 0; iteration < 3000; iteration++) {
          final HabitTargetKind kind = numeric[random.nextInt(numeric.length)];
          final int target = 1 + random.nextInt(50);
          final HabitTarget habitTarget = numericTarget(kind, target);

          final int count = random.nextInt(8);
          int expectedTotal = 0;
          final List<HabitObservation> observations = <HabitObservation>[
            for (int i = 0; i < count; i++)
              () {
                final int value = random.nextInt(20);
                expectedTotal += value;
                return HabitObservation.value(value);
              }(),
          ];
          final bool closed = random.nextBool();

          final HabitProjection p = HabitProjectionPolicy.project(
            target: habitTarget,
            observations: observations,
            isClosed: closed,
          );

          // The normalized total is exactly the sum of contributions and is
          // never negative (R-HABIT-003 partial accumulation).
          expect(p.normalizedTotal, expectedTotal);
          expect(p.normalizedTotal, greaterThanOrEqualTo(0));

          final bool met = expectedTotal >= target;
          expect(p.met, met);
          if (met) {
            expect(p.status, HabitOccurrenceStatus.completed);
          } else if (closed) {
            // Closed below target is a decisive miss.
            expect(p.status, HabitOccurrenceStatus.missed);
          } else {
            // Still open: partial totals below the target stay open.
            expect(p.status, HabitOccurrenceStatus.open);
          }
          // Numeric kinds never register an abstinence violation.
          expect(p.hasViolation, isFalse);
        }
      });

      test('a completed numeric occurrence stays completed once the target is '
          'met regardless of close', () {
        final HabitTarget target = HabitTarget.count(3);
        final List<HabitObservation> met = <HabitObservation>[
          const HabitObservation.value(2),
          const HabitObservation.value(1),
        ];
        for (final bool closed in <bool>[false, true]) {
          expect(
            HabitProjectionPolicy.project(
              target: target,
              observations: met,
              isClosed: closed,
            ).status,
            HabitOccurrenceStatus.completed,
          );
        }
      });
    },
  );

  group('[TEST-HABIT-KIND-PROP-BOOL][MVP][TASK-7.6][R-HABIT-002,R-HABIT-003] '
      'boolean target-kind projection', () {
    test('completes exactly when a true observation is present', () {
      final Random random = Random(0xB001);
      for (int iteration = 0; iteration < 2000; iteration++) {
        final int trues = random.nextInt(4);
        final int noise = random.nextInt(4);
        final List<HabitObservation> observations = <HabitObservation>[
          for (int i = 0; i < trues; i++) const HabitObservation.booleanTrue(),
          // `correct`/value observations are irrelevant noise for boolean.
          for (int i = 0; i < noise; i++) const HabitObservation.value(0),
        ]..shuffle(random);
        final bool closed = random.nextBool();

        final HabitProjection p = HabitProjectionPolicy.project(
          target: HabitTarget.boolean(),
          observations: observations,
          isClosed: closed,
        );

        if (trues > 0) {
          expect(p.status, HabitOccurrenceStatus.completed);
        } else if (closed) {
          expect(p.status, HabitOccurrenceStatus.missed);
        } else {
          expect(p.status, HabitOccurrenceStatus.open);
        }
        expect(p.normalizedTotal, 0);
      }
    });
  });

  group('[TEST-HABIT-KIND-PROP-ABST][MVP][TASK-7.6][R-HABIT-002,R-HABIT-003] '
      'abstinence target-kind projection', () {
    test('is missed on any current violation and completes only on close '
        'with no violation', () {
      final Random random = Random(0xAB57);
      for (int iteration = 0; iteration < 2000; iteration++) {
        final int violations = random.nextInt(3);
        final int cleared = random.nextInt(3);
        // A cleared/retracted observation is a `correct` record; it must not
        // count as a violation (R-HABIT-005 clear-a-violation path).
        final List<HabitObservation> observations = <HabitObservation>[
          for (int i = 0; i < violations; i++)
            const HabitObservation.violation(),
          for (int i = 0; i < cleared; i++) const HabitObservation.value(0),
        ]..shuffle(random);
        final bool closed = random.nextBool();

        final HabitProjection p = HabitProjectionPolicy.project(
          target: HabitTarget.abstinence(),
          observations: observations,
          isClosed: closed,
        );

        expect(p.hasViolation, violations > 0);
        if (violations > 0) {
          expect(p.status, HabitOccurrenceStatus.missed);
        } else if (closed) {
          expect(p.status, HabitOccurrenceStatus.completed);
        } else {
          expect(p.status, HabitOccurrenceStatus.open);
        }
        expect(p.normalizedTotal, 0);
      }
    });

    test('a period whose only current observations are retractions completes '
        'on close (the violation was cleared)', () {
      final HabitProjection p = HabitProjectionPolicy.project(
        target: HabitTarget.abstinence(),
        // The superseding retraction is the only current record; the prior
        // violation is no longer current.
        observations: const <HabitObservation>[HabitObservation.value(0)],
        isClosed: true,
      );
      expect(p.hasViolation, isFalse);
      expect(p.status, HabitOccurrenceStatus.completed);
    });
  });

  group(
    '[TEST-HABIT-KIND-INVALID][MVP][TASK-7.6][R-HABIT-002,R-HABIT-003] invalid '
    'target values are rejected at construction',
    () {
      test('zero/negative numeric targets and missing units are rejected', () {
        expect(() => HabitTarget.count(0), throwsFormatException);
        expect(() => HabitTarget.count(-3), throwsFormatException);
        expect(
          () => HabitTarget.duration(targetSeconds: 0, displayUnit: 'minutes'),
          throwsFormatException,
        );
        expect(
          () => HabitTarget.quantity(targetValue: 10, unit: ''),
          throwsFormatException,
        );
        expect(
          () => HabitTarget.quantity(targetValue: 0, unit: 'ml'),
          throwsFormatException,
        );
      });
    },
  );
}
