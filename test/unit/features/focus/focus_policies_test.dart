import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/focus/domain/focus_policies.dart';

/// Interval-union proofs for combined focus/study metrics (R-FOCUS-005).
///
/// Overlapping time is unioned, never summed as independent time, and the
/// operation is deterministic and order-independent.
///
/// **Validates: Requirements R-FOCUS-005**
void main() {
  const int s = FocusPolicies.microsPerSecond;

  FocusTimeSpan span(int startSec, int endSec) =>
      FocusTimeSpan(startUtc: startSec * s, endUtc: endSec * s);

  group('[TEST-FOCUS-UNION][MVP][TASK-7.3][R-FOCUS-005] interval union', () {
    test('disjoint spans sum', () {
      expect(
        FocusPolicies.unionDurationSec(<FocusTimeSpan>[
          span(0, 60),
          span(120, 150),
        ]),
        90,
      );
    });

    test('overlapping spans are counted once', () {
      // 09:00-10:00 and 09:30-10:30 union to 09:00-10:30 = 5400s.
      expect(
        FocusPolicies.unionDurationSec(<FocusTimeSpan>[
          span(0, 3600),
          span(1800, 5400),
        ]),
        5400,
      );
    });

    test('a fully contained span adds nothing', () {
      expect(
        FocusPolicies.unionDurationSec(<FocusTimeSpan>[
          span(0, 3600),
          span(600, 1200),
        ]),
        3600,
      );
    });

    test('touching spans merge without gap or overlap', () {
      expect(
        FocusPolicies.unionDurationSec(<FocusTimeSpan>[
          span(0, 60),
          span(60, 120),
        ]),
        120,
      );
      expect(
        FocusPolicies.hasOverlap(<FocusTimeSpan>[span(0, 60), span(60, 120)]),
        isFalse,
      );
    });

    test('overlap detection', () {
      expect(
        FocusPolicies.hasOverlap(<FocusTimeSpan>[span(0, 60), span(30, 90)]),
        isTrue,
      );
    });

    test('empty and zero-length spans contribute nothing', () {
      expect(FocusPolicies.unionDurationSec(const <FocusTimeSpan>[]), 0);
      expect(FocusPolicies.unionDurationSec(<FocusTimeSpan>[span(10, 10)]), 0);
    });
  });

  test(
    '[TEST-FOCUS-UNION-PROP][MVP][TASK-7.3][R-FOCUS-005] union never exceeds '
    'the naive sum and is order-independent',
    () {
      final Random random = Random(101);
      for (int i = 0; i < 400; i += 1) {
        final int count = 1 + random.nextInt(8);
        final List<FocusTimeSpan> spans = <FocusTimeSpan>[];
        int naiveSum = 0;
        for (int j = 0; j < count; j += 1) {
          final int start = random.nextInt(1000);
          final int len = random.nextInt(400);
          spans.add(span(start, start + len));
          naiveSum += len;
        }
        final int union = FocusPolicies.unionDurationSec(spans);
        // The union is bounded above by the naive sum (overlap never adds).
        expect(union, lessThanOrEqualTo(naiveSum));
        // Order-independence: shuffling the input yields the same union.
        final List<FocusTimeSpan> shuffled = spans.toList()..shuffle(random);
        expect(FocusPolicies.unionDurationSec(shuffled), union);
      }
    },
  );
}
