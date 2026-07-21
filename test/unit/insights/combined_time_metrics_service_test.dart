import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';

/// A fake focus contract that returns preconfigured in-range work spans.
final class _FakeFocus implements FocusDurationContract {
  _FakeFocus(this.spans);

  final List<TimeSpan> spans;

  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => spans;
}

/// A fake study contract that returns preconfigured in-range study spans.
final class _FakeStudy implements StudyDurationContract {
  _FakeStudy(this.spans);

  final List<TimeSpan> spans;

  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => spans;
}

void main() {
  final ProfileId profile = ProfileId('profile-1');
  const int s = IntervalUnion.microsPerSecond;

  TimeSpan span(int startSec, int endSec) =>
      TimeSpan(startUtc: startSec * s, endUtc: endSec * s);

  Future<CombinedTimeMetrics> compute(
    List<TimeSpan> focus,
    List<TimeSpan> study,
  ) {
    final CombinedTimeMetricsService service = CombinedTimeMetricsService(
      focusDuration: _FakeFocus(focus),
      studyDuration: _FakeStudy(study),
    );
    return service.combinedTime(
      profile,
      rangeStartUtc: 0,
      rangeEndUtc: 100000 * s,
    );
  }

  group(
    '[TEST-INSIGHT-COMBINED][V1][TASK-7.4][R-INSIGHT-001] combined time',
    () {
      test('disjoint focus and study time sum', () async {
        final CombinedTimeMetrics m = await compute(
          <TimeSpan>[span(0, 60)],
          <TimeSpan>[span(120, 180)],
        );
        expect(m.focusSeconds, 60);
        expect(m.studySeconds, 60);
        expect(m.combinedSeconds, 120);
        expect(m.overlapSeconds, 0);
      });

      test('a focus session linked to an overlapping study session is counted '
          'once, not summed', () async {
        // 09:00-10:00 focus and 09:30-10:30 study: union is 09:00-10:30 = 5400s
        // even though the naive sum would be 7200s.
        final CombinedTimeMetrics m = await compute(
          <TimeSpan>[span(0, 3600)],
          <TimeSpan>[span(1800, 5400)],
        );
        expect(m.focusSeconds, 3600);
        expect(m.studySeconds, 3600);
        expect(m.combinedSeconds, 5400);
        expect(m.overlapSeconds, 1800);
      });

      test('fully overlapping focus and study add no extra time', () async {
        final CombinedTimeMetrics m = await compute(
          <TimeSpan>[span(0, 3600)],
          <TimeSpan>[span(0, 3600)],
        );
        expect(m.combinedSeconds, 3600);
        expect(m.overlapSeconds, 3600);
      });

      test('no data yields zero, not a fabricated total', () async {
        final CombinedTimeMetrics m = await compute(
          const <TimeSpan>[],
          const <TimeSpan>[],
        );
        expect(m.combinedSeconds, 0);
        expect(m.overlapSeconds, 0);
      });

      test('a descending range is rejected', () async {
        final CombinedTimeMetricsService service = CombinedTimeMetricsService(
          focusDuration: _FakeFocus(const <TimeSpan>[]),
          studyDuration: _FakeStudy(const <TimeSpan>[]),
        );
        expect(
          () =>
              service.combinedTime(profile, rangeStartUtc: 100, rangeEndUtc: 0),
          throwsFormatException,
        );
      });
    },
  );

  // Property: overlapping intervals across study + focus are counted exactly
  // once. The combined total is the union of both span sets, never their sum,
  // and it degrades to the sum precisely when the two sets are disjoint.
  //
  // **Validates: Requirements R-INSIGHT-001, R-LEARN-002**
  group(
    '[TEST-INSIGHT-COMBINED-PROP][V1][TASK-7.4][R-INSIGHT-001] properties',
    () {
      // Second-aligned spans keep whole-second truncation exact.
      List<TimeSpan> randomSpans(Random random, int count) => <TimeSpan>[
        for (int i = 0; i < count; i += 1)
          () {
            final int start = random.nextInt(1000);
            return span(start, start + random.nextInt(120));
          }(),
      ];

      test('combined equals the union of both sets and never double counts '
          'overlap', () async {
        for (final int seed in <int>[3, 11, 57, 808, 2024]) {
          final Random random = Random(seed);
          for (int i = 0; i < 120; i += 1) {
            final List<TimeSpan> focus = randomSpans(random, random.nextInt(5));
            final List<TimeSpan> study = randomSpans(random, random.nextInt(5));
            final CombinedTimeMetrics m = await compute(focus, study);

            final int expectedCombined = IntervalUnion.unionSeconds(<TimeSpan>[
              ...focus,
              ...study,
            ]);
            // Counted exactly once: the union of everything.
            expect(m.combinedSeconds, expectedCombined);
            // Overlap is never summed as independent time.
            expect(
              m.combinedSeconds,
              lessThanOrEqualTo(m.focusSeconds + m.studySeconds),
            );
            // The reported overlap reconciles the three totals exactly.
            expect(
              m.overlapSeconds,
              m.focusSeconds + m.studySeconds - m.combinedSeconds,
            );
            expect(m.overlapSeconds, greaterThanOrEqualTo(0));
          }
        }
      });

      test('disjoint focus and study sum with zero overlap', () async {
        final Random random = Random(9001);
        for (int i = 0; i < 200; i += 1) {
          // Focus strictly before 5000s, study strictly after, never touching.
          final int fStart = random.nextInt(1000);
          final int sStart = 6000 + random.nextInt(1000);
          final CombinedTimeMetrics m = await compute(
            <TimeSpan>[span(fStart, fStart + 1 + random.nextInt(500))],
            <TimeSpan>[span(sStart, sStart + 1 + random.nextInt(500))],
          );
          expect(m.combinedSeconds, m.focusSeconds + m.studySeconds);
          expect(m.overlapSeconds, 0);
        }
      });
    },
  );
}
