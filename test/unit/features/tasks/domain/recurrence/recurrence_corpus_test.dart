import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_engine.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_weekday.dart';

/// Generative recurrence corpus asserting universal engine invariants across a
/// deterministic sample of rules. Seeds are fixed so a failure is reproducible.
///
/// **Validates: Requirements R-TASK-005, R-TASK-006**
void main() {
  // A deterministic, well-known timezone set. The engine works in local dates
  // only, so the zone is carried for validity but does not affect keys.
  const List<String> zones = <String>[
    'Etc/UTC',
    'America/New_York',
    'Europe/London',
    'Australia/Sydney',
  ];

  RecurrenceRule generate(Random random) {
    final RecurrenceFrequency frequency =
        RecurrenceFrequency.values[random.nextInt(4)];
    final int interval = 1 + random.nextInt(4);
    final LocalDate start = LocalDate(
      2020 + random.nextInt(6),
      1 + random.nextInt(12),
      1 + random.nextInt(28),
    );

    Set<RecurrenceWeekday>? byWeekdays;
    if (frequency == RecurrenceFrequency.weekly && random.nextBool()) {
      byWeekdays = <RecurrenceWeekday>{};
      for (final RecurrenceWeekday day in RecurrenceWeekday.values) {
        if (random.nextInt(3) == 0) {
          byWeekdays.add(day);
        }
      }
      if (byWeekdays.isEmpty) {
        byWeekdays = null;
      }
    }

    Set<int>? byMonthDays;
    if ((frequency == RecurrenceFrequency.monthly ||
            frequency == RecurrenceFrequency.yearly) &&
        random.nextBool()) {
      byMonthDays = <int>{1 + random.nextInt(31)};
    }

    final RecurrenceEnd end = switch (random.nextInt(3)) {
      0 => RecurrenceEnd.count(1 + random.nextInt(12)),
      1 => RecurrenceEnd.until(start.addDays(30 + random.nextInt(700))),
      _ => RecurrenceEnd.never,
    };

    return RecurrenceRule(
      frequency: frequency,
      start: start,
      timezoneId: zones[random.nextInt(zones.length)],
      interval: interval,
      byWeekdays: byWeekdays,
      byMonthDays: byMonthDays,
      end: end,
    );
  }

  test('generated rules satisfy ordering, membership, and next invariants', () {
    const int cases = 400;
    for (int seed = 0; seed < cases; seed += 1) {
      final Random random = Random(seed);
      final RecurrenceRule rule = generate(random);
      final List<LocalDate> occurrences = RecurrenceEngine.take(
        rule,
        limit: 12,
      );

      // Strictly ascending, unique keys.
      for (int i = 1; i < occurrences.length; i += 1) {
        expect(
          occurrences[i - 1] < occurrences[i],
          isTrue,
          reason: 'seed $seed: occurrences not strictly ascending',
        );
      }

      // Every generated key is a real occurrence, and never before the start.
      for (final LocalDate occurrence in occurrences) {
        expect(
          occurrence >= rule.start,
          isTrue,
          reason: 'seed $seed: occurrence precedes start',
        );
        expect(
          RecurrenceEngine.isOccurrence(rule, occurrence),
          isTrue,
          reason: 'seed $seed: $occurrence not recognized as an occurrence',
        );
      }

      // next() from occurrence i yields occurrence i+1.
      for (int i = 0; i + 1 < occurrences.length; i += 1) {
        expect(
          RecurrenceEngine.next(rule, occurrences[i]),
          occurrences[i + 1],
          reason: 'seed $seed: next mismatch at index $i',
        );
      }

      // COUNT bounds the total number of raw (and therefore real) occurrences.
      final RecurrenceEnd end = rule.end;
      if (end is CountLimit) {
        expect(
          occurrences.length <= end.count,
          isTrue,
          reason: 'seed $seed: exceeded COUNT bound',
        );
      }

      // UNTIL bounds by date.
      if (end is UntilDate) {
        for (final LocalDate occurrence in occurrences) {
          expect(
            occurrence <= end.date,
            isTrue,
            reason: 'seed $seed: occurrence past UNTIL',
          );
        }
      }
    }
  });

  test('occurrence generation is deterministic across runs', () {
    for (int seed = 0; seed < 100; seed += 1) {
      final RecurrenceRule ruleA = generate(Random(seed));
      final RecurrenceRule ruleB = generate(Random(seed));
      expect(
        RecurrenceEngine.take(
          ruleA,
          limit: 10,
        ).map((LocalDate d) => d.iso).toList(),
        RecurrenceEngine.take(
          ruleB,
          limit: 10,
        ).map((LocalDate d) => d.iso).toList(),
        reason: 'seed $seed: engine is not deterministic',
      );
    }
  });

  test('exceptions never appear and preserve ordering', () {
    for (int seed = 0; seed < 100; seed += 1) {
      final Random random = Random(1000 + seed);
      final RecurrenceRule base = generate(random);
      final List<LocalDate> raw = RecurrenceEngine.take(base, limit: 8);
      if (raw.length < 3) {
        continue;
      }
      final LocalDate excluded = raw[1];
      final RecurrenceRule ruled = base.withExceptions(<LocalDate>{excluded});
      final List<LocalDate> filtered = RecurrenceEngine.take(ruled, limit: 8);
      expect(
        filtered.contains(excluded),
        isFalse,
        reason: 'seed $seed: excluded key still present',
      );
      expect(
        RecurrenceEngine.isOccurrence(ruled, excluded),
        isFalse,
        reason: 'seed $seed: excluded key still recognized',
      );
    }
  });
}
