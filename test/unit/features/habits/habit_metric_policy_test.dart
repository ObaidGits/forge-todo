import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';

/// Metric-policy-v1 streak and consistency semantics (R-HABIT-004, R-HABIT-007).
void main() {
  group('given ordered outcomes when computing the current streak', () {
    test('counts consecutive completed periods walking backward', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 3);
    });

    test('a miss stops the walk', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.missed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
      ];
      // Walk backward from the last completed: 2, stopped by the miss.
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 2);
    });

    test('a skip is neutral: stepped over without counting or breaking', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.skipped,
        HabitPeriodOutcome.completed,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 2);
    });

    test('a paused occurrence is ignored and does not break continuity', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.paused,
        HabitPeriodOutcome.completed,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 2);
    });

    test('a trailing skip/pause defers to the last decisive occurrence', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.skipped,
        HabitPeriodOutcome.paused,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 2);
    });

    test('a trailing miss yields a zero current streak', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.missed,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 0);
    });

    test('an open (incomplete, unclosed) period stops the walk', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.open,
        HabitPeriodOutcome.completed,
      ];
      expect(HabitMetricPolicyV1.currentStreak(outcomes), 1);
    });
  });

  group('given ordered outcomes when computing consistency', () {
    test('is completed eligible over all eligible', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.missed,
        HabitPeriodOutcome.completed,
      ];
      final HabitConsistency c = HabitMetricPolicyV1.consistency(outcomes);
      expect(c.completed, 3);
      expect(c.denominator, 4);
      expect(c.ratio, closeTo(0.75, 1e-9));
    });

    test('paused occurrences are excluded from both numerator/denominator', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.paused,
        HabitPeriodOutcome.missed,
      ];
      final HabitConsistency c = HabitMetricPolicyV1.consistency(outcomes);
      expect(c.completed, 1);
      expect(c.denominator, 2);
    });

    test('skips stay in the denominator but never the numerator', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.completed,
        HabitPeriodOutcome.skipped,
      ];
      final HabitConsistency c = HabitMetricPolicyV1.consistency(outcomes);
      expect(c.completed, 1);
      expect(c.denominator, 2);
      expect(c.ratio, closeTo(0.5, 1e-9));
    });

    test('a zero denominator yields no eligible data, not 0%', () {
      const List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
        HabitPeriodOutcome.paused,
        HabitPeriodOutcome.paused,
      ];
      final HabitConsistency c = HabitMetricPolicyV1.consistency(outcomes);
      expect(c.hasData, isFalse);
      expect(c.ratio, isNull);
    });
  });

  group('given randomized outcome sequences (property based)', () {
    // Property: consistency is always numerator/denominator with paused
    // excluded and skips in the denominator only; the ratio is null exactly
    // when the eligible denominator is zero; and the current streak is never
    // greater than the number of completed occurrences.
    test('metric invariants hold across random sequences', () {
      final Random random = Random(0xF00D);
      const List<HabitPeriodOutcome> palette = HabitPeriodOutcome.values;
      for (int iteration = 0; iteration < 2000; iteration++) {
        final int length = random.nextInt(20);
        final List<HabitPeriodOutcome> outcomes = <HabitPeriodOutcome>[
          for (int i = 0; i < length; i++)
            palette[random.nextInt(palette.length)],
        ];

        final int completedCount = outcomes
            .where((HabitPeriodOutcome o) => o == HabitPeriodOutcome.completed)
            .length;
        final int pausedCount = outcomes
            .where((HabitPeriodOutcome o) => o == HabitPeriodOutcome.paused)
            .length;

        final HabitConsistency c = HabitMetricPolicyV1.consistency(outcomes);
        expect(c.completed, completedCount);
        expect(c.denominator, outcomes.length - pausedCount);
        expect(c.ratio == null, c.denominator == 0);
        if (c.ratio != null) {
          expect(c.ratio, inInclusiveRange(0.0, 1.0));
        }

        final int streak = HabitMetricPolicyV1.currentStreak(outcomes);
        expect(streak, lessThanOrEqualTo(completedCount));
        expect(streak, greaterThanOrEqualTo(0));
      }
    });

    // Property: inserting a paused or skipped occurrence between two completed
    // occurrences never reduces the streak below what it would be if that
    // neutral occurrence were absent (neutrality for continuity).
    test('neutral occurrences never break an otherwise continuous streak', () {
      final Random random = Random(0xBEEF);
      for (int iteration = 0; iteration < 500; iteration++) {
        final int completed = 1 + random.nextInt(6);
        final List<HabitPeriodOutcome> withoutNeutral = <HabitPeriodOutcome>[
          for (int i = 0; i < completed; i++) HabitPeriodOutcome.completed,
        ];
        // Insert neutral occurrences at random positions.
        final List<HabitPeriodOutcome> withNeutral =
            List<HabitPeriodOutcome>.of(withoutNeutral);
        final int inserts = random.nextInt(4);
        for (int i = 0; i < inserts; i++) {
          final HabitPeriodOutcome neutral = random.nextBool()
              ? HabitPeriodOutcome.skipped
              : HabitPeriodOutcome.paused;
          withNeutral.insert(random.nextInt(withNeutral.length + 1), neutral);
        }
        expect(
          HabitMetricPolicyV1.currentStreak(withNeutral),
          HabitMetricPolicyV1.currentStreak(withoutNeutral),
        );
      }
    });
  });
}
