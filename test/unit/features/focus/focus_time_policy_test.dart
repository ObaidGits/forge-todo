import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/focus/domain/focus_time_policy.dart';

/// Pure timer-truth reconciliation proofs (R-FOCUS-002).
///
/// While the boot id matches, the monotonic clock is authoritative and immune
/// to wall-clock changes; after a boot change the segment falls back to a
/// bounded wall-clock delta and becomes an explicit correction prompt when the
/// wall clock is implausible.
///
/// **Validates: Requirements R-FOCUS-002**
void main() {
  const String bootA = 'boot-A';
  const String bootB = 'boot-B';
  const int wallAnchor = 1_700_000_000_000_000; // arbitrary UTC micros

  TimerTruth truth({Duration mono = Duration.zero}) => TimerTruth(
    bootSessionId: bootA,
    monotonicAnchor: mono,
    wallAnchorUtcMicros: wallAnchor,
  );

  group('[TEST-FOCUS-TIME-SAMEBOOT][MVP][TASK-7.3][R-FOCUS-002] same boot uses '
      'the monotonic clock', () {
    test('monotonic delta is authoritative and ignores wall changes', () {
      final ElapsedResolution r = FocusTimePolicy.resolveSegment(
        truth(mono: const Duration(seconds: 10)),
        const TimerReading(
          bootSessionId: bootA,
          monotonic: Duration(minutes: 30, seconds: 10),
          // Wall clock jumped backwards by an hour; must be ignored.
          wallUtcMicros: wallAnchor - Duration.microsecondsPerHour,
        ),
      );
      expect(
        r,
        const ElapsedKnown(
          segment: Duration(minutes: 30),
          source: ElapsedSource.monotonic,
        ),
      );
    });

    test('an 8-hour timer resolves exactly from the monotonic clock', () {
      final ElapsedResolution r = FocusTimePolicy.resolveSegment(
        truth(),
        const TimerReading(
          bootSessionId: bootA,
          monotonic: Duration(hours: 8),
          wallUtcMicros: wallAnchor + 8 * Duration.microsecondsPerHour,
        ),
      );
      expect(r, isA<ElapsedKnown>());
      expect((r as ElapsedKnown).segment, const Duration(hours: 8));
      expect(r.source, ElapsedSource.monotonic);
    });

    test('a monotonic regression under one boot is treated as ambiguous', () {
      final ElapsedResolution r = FocusTimePolicy.resolveSegment(
        truth(mono: const Duration(seconds: 100)),
        const TimerReading(
          bootSessionId: bootA,
          monotonic: Duration(seconds: 40),
          wallUtcMicros: wallAnchor + 60 * Duration.microsecondsPerSecond,
        ),
      );
      expect(r, isA<ElapsedAmbiguous>());
      expect(
        (r as ElapsedAmbiguous).reason,
        AmbiguityReason.monotonicWentBackwards,
      );
    });
  });

  group(
    '[TEST-FOCUS-TIME-REBOOT][MVP][TASK-7.3][R-FOCUS-002] boot change falls '
    'back to bounded wall reconciliation',
    () {
      test(
        'after reboot a plausible wall delta resolves via the wall clock',
        () {
          final ElapsedResolution r = FocusTimePolicy.resolveSegment(
            truth(mono: const Duration(hours: 5)),
            const TimerReading(
              // New boot: the monotonic anchor is meaningless.
              bootSessionId: bootB,
              monotonic: Duration(seconds: 3),
              wallUtcMicros: wallAnchor + 25 * Duration.microsecondsPerMinute,
            ),
            maxPlausibleSegment: Duration(hours: 2),
          );
          expect(r, isA<ElapsedKnown>());
          expect((r as ElapsedKnown).segment, const Duration(minutes: 25));
          expect(r.source, ElapsedSource.wallClock);
        },
      );

      test('a backwards wall clock after reboot is ambiguous', () {
        final ElapsedResolution r = FocusTimePolicy.resolveSegment(
          truth(),
          const TimerReading(
            bootSessionId: bootB,
            monotonic: Duration(seconds: 1),
            wallUtcMicros: wallAnchor - 5 * Duration.microsecondsPerMinute,
          ),
        );
        expect(r, isA<ElapsedAmbiguous>());
        expect(
          (r as ElapsedAmbiguous).reason,
          AmbiguityReason.wallClockWentBackwards,
        );
        expect(r.lowerBound, Duration.zero);
      });

      test('a wall delta beyond the plausibility bound is ambiguous', () {
        final ElapsedResolution r = FocusTimePolicy.resolveSegment(
          truth(),
          const TimerReading(
            bootSessionId: bootB,
            monotonic: Duration(seconds: 1),
            wallUtcMicros: wallAnchor + 10 * Duration.microsecondsPerHour,
          ),
          maxPlausibleSegment: const Duration(hours: 2),
        );
        expect(r, isA<ElapsedAmbiguous>());
        final ElapsedAmbiguous a = r as ElapsedAmbiguous;
        expect(a.reason, AmbiguityReason.wallDeltaExceedsBound);
        expect(a.lowerBound, const Duration(hours: 2));
        expect(a.wallEstimate, const Duration(hours: 10));
      });
    },
  );

  group('[TEST-FOCUS-TIME-PROP][MVP][TASK-7.3][R-FOCUS-002] generative '
      'reconciliation properties', () {
    test('same-boot elapsed equals the monotonic delta regardless of the '
        'wall clock (long-timer + wall-discontinuity)', () {
      final Random random = Random(7);
      for (int i = 0; i < 400; i += 1) {
        final int anchorMonoMs = random.nextInt(1 << 20);
        // Up to ~11.5 days of additional monotonic elapse (long-timer).
        final int deltaMs = random.nextInt(1 << 30);
        // Arbitrary, possibly backwards, wall jump — must not matter.
        final int wallJump =
            (random.nextInt(1 << 31) - (1 << 30)) *
            Duration.microsecondsPerSecond;
        final ElapsedResolution r = FocusTimePolicy.resolveSegment(
          TimerTruth(
            bootSessionId: bootA,
            monotonicAnchor: Duration(milliseconds: anchorMonoMs),
            wallAnchorUtcMicros: wallAnchor,
          ),
          TimerReading(
            bootSessionId: bootA,
            monotonic: Duration(milliseconds: anchorMonoMs + deltaMs),
            wallUtcMicros: wallAnchor + wallJump,
          ),
        );
        expect(r, isA<ElapsedKnown>());
        final ElapsedKnown k = r as ElapsedKnown;
        expect(k.source, ElapsedSource.monotonic);
        expect(k.segment, Duration(milliseconds: deltaMs));
      }
    });

    test('a boot change with a backwards wall clock is always ambiguous, never '
        'a fabricated negative duration', () {
      final Random random = Random(31);
      for (int i = 0; i < 400; i += 1) {
        final int backwardsMicros = 1 + random.nextInt(1 << 30);
        final ElapsedResolution r = FocusTimePolicy.resolveSegment(
          TimerTruth(
            bootSessionId: bootA,
            monotonicAnchor: Duration(microseconds: random.nextInt(1 << 20)),
            wallAnchorUtcMicros: wallAnchor,
          ),
          TimerReading(
            bootSessionId: bootB,
            monotonic: Duration(microseconds: random.nextInt(1 << 20)),
            wallUtcMicros: wallAnchor - backwardsMicros,
          ),
        );
        expect(r, isA<ElapsedAmbiguous>());
        expect((r as ElapsedAmbiguous).lowerBound.isNegative, isFalse);
      }
    });
  });

  test('[TEST-FOCUS-TIME-LIVE][MVP][TASK-7.3][R-FOCUS-002] live elapsed is '
      'accumulated plus the resolved segment', () {
    final ElapsedResolution known = FocusTimePolicy.resolveSegment(
      truth(),
      const TimerReading(
        bootSessionId: bootA,
        monotonic: Duration(minutes: 5),
        wallUtcMicros: wallAnchor,
      ),
    );
    expect(
      FocusTimePolicy.liveElapsed(const Duration(minutes: 20), known),
      const Duration(minutes: 25),
    );
  });
}
