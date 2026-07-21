import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/domain/combined_time_metrics.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';

/// In-process performance guard for the daily-aggregate computation that backs
/// the Daily Summary and Insights (R-INSIGHT-001, R-FOCUS-005, NFR-PERF-003).
///
/// The authoritative aggregate/dashboard-query budget (common query p95
/// ≤100 ms at reference scale, which includes 1,000,000 focus/study/check-in
/// rows) is an external reference-profile campaign
/// (tool/probes/benchmark_profile + docs/evidence/BENCHMARK-PROFILE.md). That
/// campaign is external evidence and cannot run in a unit harness.
///
/// This guard is the automated regression tripwire that complements it: the
/// hot path of the aggregate is the canonical [IntervalUnion] (used to union
/// focus and study spans without double counting) and the
/// [CombinedTimeMetricsService] that composes them. Both must stay linearithmic
/// in the number of spans; a regression to quadratic merging (e.g. an O(n²)
/// pairwise overlap check) would blow up the daily aggregate at reference
/// scale. This asserts the union of a large span set is computed well inside a
/// generous tripwire and is independent of input order. It never weakens or
/// substitutes for the reference-profile requirement.
///
/// **Validates: Requirements R-INSIGHT-001, NFR-PERF-003**
void main() {
  // Generous ceiling; the suite runs with --timeout=5x so this is not a
  // wall-clock race. A linearithmic union of this many spans is milliseconds;
  // only a super-linear regression trips it.
  const double tripwireMs = 500.0;
  const int spanCount = 100000;

  /// A large, deterministic span set with a realistic mix of disjoint and
  /// overlapping intervals (adjacent spans overlap by a third of their length).
  List<TimeSpan> buildSpans() {
    final List<TimeSpan> spans = <TimeSpan>[];
    for (int i = 0; i < spanCount; i += 1) {
      final int start = i * 100;
      // Length 150 with stride 100 => each span overlaps the next by 50.
      spans.add(TimeSpan(startUtc: start, endUtc: start + 150));
    }
    return spans;
  }

  double measureMillis(void Function() body) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0;
  }

  test(
    '[TEST-PERF-AGGREGATE-001][MVP][TASK-8.4][R-INSIGHT-001,NFR-PERF-003] the '
    'interval union of a large span set stays within the tripwire and is '
    'order-independent',
    () {
      final List<TimeSpan> ordered = buildSpans();
      // A shuffled copy must produce the identical union (order independence is
      // a correctness prerequisite for the aggregate).
      final List<TimeSpan> shuffled = List<TimeSpan>.of(ordered)
        ..shuffle(Random(42));

      late int orderedUnion;
      final double orderedMs = measureMillis(() {
        orderedUnion = IntervalUnion.unionMicros(ordered);
      });
      late int shuffledUnion;
      final double shuffledMs = measureMillis(() {
        shuffledUnion = IntervalUnion.unionMicros(shuffled);
      });

      // Correctness: union covers [0, lastEnd) minus the gaps. With stride 100
      // and length 150 every span overlaps the next, so the whole range is one
      // contiguous block: [0, (spanCount-1)*100 + 150).
      final int expected = (spanCount - 1) * 100 + 150;
      expect(orderedUnion, expected);
      expect(shuffledUnion, expected);

      expect(
        orderedMs,
        lessThan(tripwireMs),
        reason:
            'ordered interval union over $spanCount spans took '
            '${orderedMs.toStringAsFixed(2)} ms, exceeding ${tripwireMs}ms',
      );
      expect(
        shuffledMs,
        lessThan(tripwireMs),
        reason:
            'shuffled interval union over $spanCount spans took '
            '${shuffledMs.toStringAsFixed(2)} ms, exceeding ${tripwireMs}ms',
      );
    },
  );

  test(
    '[TEST-PERF-AGGREGATE-002][MVP][TASK-8.4][R-INSIGHT-001,NFR-PERF-003] the '
    'combined focus + study aggregate composes large span sets within the '
    'tripwire without double counting',
    () async {
      final List<TimeSpan> focus = buildSpans();
      // Study spans shifted by half a stride so they overlap focus spans.
      final List<TimeSpan> study = <TimeSpan>[
        for (int i = 0; i < spanCount; i += 1)
          TimeSpan(startUtc: i * 100 + 50, endUtc: i * 100 + 200),
      ];
      final CombinedTimeMetricsService service = CombinedTimeMetricsService(
        focusDuration: _FakeFocus(focus),
        studyDuration: _FakeStudy(study),
      );

      late CombinedTimeMetrics metrics;
      final Stopwatch sw = Stopwatch()..start();
      metrics = await service.combinedTime(
        ProfileId('p1'),
        rangeStartUtc: 0,
        rangeEndUtc: spanCount * 100 + 1000,
      );
      sw.stop();
      final double millis = sw.elapsedMicroseconds / 1000.0;

      // The combined union never exceeds the naive sum, and overlap is the
      // difference (never negative). This proves the aggregate is genuinely
      // computed, not short-circuited.
      expect(
        metrics.combinedSeconds,
        lessThanOrEqualTo(metrics.focusSeconds + metrics.studySeconds),
      );
      expect(metrics.overlapSeconds, greaterThan(0));
      expect(
        millis,
        lessThan(tripwireMs),
        reason:
            'combined focus+study aggregate over ${spanCount * 2} spans took '
            '${millis.toStringAsFixed(2)} ms, exceeding ${tripwireMs}ms',
      );
    },
  );
}

/// A fixed-list focus duration contract.
final class _FakeFocus implements FocusDurationContract {
  const _FakeFocus(this._spans);
  final List<TimeSpan> _spans;

  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => _spans;
}

/// A fixed-list study duration contract.
final class _FakeStudy implements StudyDurationContract {
  const _FakeStudy(this._spans);
  final List<TimeSpan> _spans;

  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => _spans;
}
