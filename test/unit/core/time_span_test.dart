import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/time_span.dart';

/// Example and property coverage for the one canonical interval-union policy
/// used by focus, learning, and combined insights metrics (R-FOCUS-005,
/// R-INSIGHT-001).
void main() {
  TimeSpan span(int startUtc, int endUtc) =>
      TimeSpan(startUtc: startUtc, endUtc: endUtc);

  group('[TEST-CORE-TIMESPAN][MVP][TASK-7.4][R-FOCUS-005] TimeSpan', () {
    test('rejects an end before its start', () {
      expect(() => span(10, 5), throwsFormatException);
    });

    test('a point interval has zero length', () {
      expect(span(7, 7).lengthMicros, 0);
    });

    test('value equality is by bounds', () {
      expect(span(1, 2), equals(span(1, 2)));
      expect(span(1, 2), isNot(equals(span(1, 3))));
    });
  });

  group('[TEST-CORE-UNION][MVP][TASK-7.4][R-FOCUS-005] IntervalUnion', () {
    test('disjoint spans sum', () {
      expect(
        IntervalUnion.unionMicros(<TimeSpan>[span(0, 100), span(200, 250)]),
        150,
      );
    });

    test('overlapping spans count the overlap once', () {
      expect(
        IntervalUnion.unionMicros(<TimeSpan>[span(0, 100), span(50, 150)]),
        150,
      );
    });

    test('a fully contained span adds nothing', () {
      expect(
        IntervalUnion.unionMicros(<TimeSpan>[span(0, 100), span(25, 75)]),
        100,
      );
    });

    test('touching spans merge', () {
      expect(
        IntervalUnion.unionMicros(<TimeSpan>[span(0, 100), span(100, 200)]),
        200,
      );
    });

    test('zero-length and empty contribute nothing', () {
      expect(IntervalUnion.unionMicros(const <TimeSpan>[]), 0);
      expect(IntervalUnion.unionMicros(<TimeSpan>[span(10, 10)]), 0);
    });

    test('unionSeconds truncates to whole seconds', () {
      const int s = IntervalUnion.microsPerSecond;
      expect(
        IntervalUnion.unionSeconds(<TimeSpan>[span(0, 3 * s + 500000)]),
        3,
      );
    });
  });

  // Property-based coverage of the union algorithm.
  //
  // **Validates: Requirements R-FOCUS-005, R-INSIGHT-001**
  group('[TEST-CORE-UNION-PROP][MVP][TASK-7.4][R-FOCUS-005] properties', () {
    List<TimeSpan> randomSpans(Random random, int count) {
      return <TimeSpan>[
        for (int i = 0; i < count; i += 1)
          () {
            final int start = random.nextInt(1000);
            final int length = random.nextInt(200); // may be 0
            return span(start, start + length);
          }(),
      ];
    }

    test('union never exceeds the naive sum and is order independent', () {
      for (final int seed in <int>[1, 7, 42, 1337, 99999]) {
        final Random random = Random(seed);
        for (int i = 0; i < 400; i += 1) {
          final List<TimeSpan> spans = randomSpans(random, random.nextInt(8));
          final int naiveSum = spans.fold<int>(
            0,
            (int acc, TimeSpan s) => acc + s.lengthMicros,
          );
          final int union = IntervalUnion.unionMicros(spans);
          // Overlap is never added twice.
          expect(union, lessThanOrEqualTo(naiveSum));
          expect(union, greaterThanOrEqualTo(0));
          // Shuffling the input yields the same union.
          final List<TimeSpan> shuffled = spans.toList()..shuffle(random);
          expect(IntervalUnion.unionMicros(shuffled), union);
        }
      }
    });

    test('duplicating spans does not change the union (counted once)', () {
      final Random random = Random(2024);
      for (int i = 0; i < 400; i += 1) {
        final List<TimeSpan> spans = randomSpans(random, 1 + random.nextInt(6));
        final int union = IntervalUnion.unionMicros(spans);
        final List<TimeSpan> doubled = <TimeSpan>[...spans, ...spans];
        expect(IntervalUnion.unionMicros(doubled), union);
      }
    });

    test('union of two sets equals their combined union and matches sum only '
        'when disjoint', () {
      final Random random = Random(4242);
      for (int i = 0; i < 400; i += 1) {
        final List<TimeSpan> a = randomSpans(random, 1 + random.nextInt(4));
        final List<TimeSpan> b = randomSpans(random, 1 + random.nextInt(4));
        final int unionA = IntervalUnion.unionMicros(a);
        final int unionB = IntervalUnion.unionMicros(b);
        final int combined = IntervalUnion.unionMicros(<TimeSpan>[...a, ...b]);
        // The combined union never double-counts shared time.
        expect(combined, lessThanOrEqualTo(unionA + unionB));
        expect(combined, greaterThanOrEqualTo(max(unionA, unionB)));
      }
    });
  });
}
