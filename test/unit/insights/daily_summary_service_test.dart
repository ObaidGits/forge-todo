import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/daily_summary_service.dart';
import 'package:forge/features/insights/domain/daily_summary.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';

/// A fake planner summary contract that returns a preconfigured snapshot.
final class _FakePlanner implements PlannerSummaryContract {
  _FakePlanner(this.snapshot);

  PlannerDailyCloseSnapshot? snapshot;

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async => snapshot;

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async => <PlannerDailyCloseSnapshot>[?snapshot];
}

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
  final LifeAreaId area = LifeAreaId('area-1');
  const int s = IntervalUnion.microsPerSecond;

  TimeSpan span(int startSec, int endSec) =>
      TimeSpan(startUtc: startSec * s, endUtc: endSec * s);

  PlannerTaskCloseTally tally({
    int eligible = 4,
    int completed = 2,
    int missed = 1,
    int carried = 0,
  }) => PlannerTaskCloseTally(
    eligibleCount: eligible,
    completedCount: completed,
    missedCount: missed,
    carriedCount: carried,
    eligibleRootHash: 'elig-hash',
    completedRootHash: 'done-hash',
  );

  PlannerDailyCloseSnapshot snapshot({
    PlannerTaskCloseTally? tasks,
    List<PlannerHabitCloseOutcome> habits = const <PlannerHabitCloseOutcome>[],
    int adjustmentCount = 0,
    int metricPolicyNumber = 1,
    int watermark = 100,
    String? reflectionMd,
  }) => PlannerDailyCloseSnapshot(
    periodId: 'period-1',
    closedAtUtc: 2000,
    boundaryUtc: 1500,
    metricPolicyNumber: metricPolicyNumber,
    sourceWatermarkCommitSeq: watermark,
    tasks: tasks ?? tally(),
    habits: habits,
    adjustmentCount: adjustmentCount,
    reflectionMd: reflectionMd,
  );

  DailySummaryService serviceFor(
    PlannerDailyCloseSnapshot? snap, {
    List<TimeSpan> focus = const <TimeSpan>[],
    List<TimeSpan> study = const <TimeSpan>[],
  }) => DailySummaryService(
    plannerSummary: _FakePlanner(snap),
    combinedTime: CombinedTimeMetricsService(
      focusDuration: _FakeFocus(focus),
      studyDuration: _FakeStudy(study),
    ),
  );

  Future<DailySummary?> summarize(DailySummaryService service) =>
      service.summarize(
        profile,
        lifeAreaId: area,
        dayKey: '2024-06-01',
        dayStartUtc: 0,
        dayEndUtc: 100000 * s,
      );

  group(
    '[TEST-INSIGHT-DAILY-SUMMARY][MVP][TASK-8.1][R-HOME-004] composition',
    () {
      test('there is no summary before the day is closed', () async {
        final DailySummary? result = await summarize(serviceFor(null));
        expect(result, isNull);
      });

      test('the summary composes task completion, habits, time, reflection, '
          'policy version, and watermark', () async {
        final DailySummary result = (await summarize(
          serviceFor(
            snapshot(
              tasks: tally(eligible: 4, completed: 3),
              habits: const <PlannerHabitCloseOutcome>[
                PlannerHabitCloseOutcome(
                  occurrenceId: 'h1',
                  statusWire: 'completed',
                ),
                PlannerHabitCloseOutcome(
                  occurrenceId: 'h2',
                  statusWire: 'missed',
                ),
              ],
              watermark: 512,
              reflectionMd: 'Grateful for a focused morning.',
            ),
            focus: <TimeSpan>[span(0, 3600)],
            study: <TimeSpan>[span(1800, 5400)],
          ),
        ))!;

        expect(result.taskCompletion.numerator, 3);
        expect(result.taskCompletion.denominator, 4);
        expect(result.habits.completed, 1);
        expect(result.habits.missed, 1);
        // Interval-union of 09:00-10:00 focus and 09:30-10:30 study = 5400s.
        expect(result.combinedFocusStudySeconds, 5400);
        expect(result.focusStudyOverlapSeconds, 1800);
        expect(result.reflectionMd, 'Grateful for a focused morning.');
        expect(result.metricPolicyVersion, 'metric-policy-v1');
        expect(result.sourceWatermarkCommitSeq, 512);
        expect(result.eligibleRootHash, 'elig-hash');
      });
    },
  );

  group('[TEST-INSIGHT-DAILY-SUMMARY-HABITS][MVP][TASK-8.1][R-HABIT-007] '
      'habit outcome tally', () {
    test('paused occurrences are excluded and a skip stays in the '
        'denominator only', () async {
      final DailySummary result = (await summarize(
        serviceFor(
          snapshot(
            habits: const <PlannerHabitCloseOutcome>[
              PlannerHabitCloseOutcome(
                occurrenceId: 'h1',
                statusWire: 'completed',
              ),
              PlannerHabitCloseOutcome(
                occurrenceId: 'h2',
                statusWire: 'skipped',
              ),
              PlannerHabitCloseOutcome(
                occurrenceId: 'h3',
                statusWire: 'paused',
              ),
              PlannerHabitCloseOutcome(
                occurrenceId: 'h4',
                statusWire: 'missed',
              ),
            ],
          ),
        ),
      ))!;

      expect(result.habits.completed, 1);
      expect(result.habits.skipped, 1);
      expect(result.habits.paused, 1);
      expect(result.habits.missed, 1);
      // Denominator excludes the paused one: completed/(completed+skip+miss).
      expect(result.habits.completion.numerator, 1);
      expect(result.habits.completion.denominator, 3);
    });

    test('no scheduled habits yields no-data, not 0%', () async {
      final DailySummary result = (await summarize(serviceFor(snapshot())))!;
      expect(result.habits.completion.hasData, isFalse);
      expect(result.habits.completion.ratio, isNull);
    });
  });

  // Property: the as-of-close summary is invariant under later mutation. Given
  // the same sealed close counts, the number of appended adjustments never
  // changes the displayed task/habit values or the policy version — corrections
  // append records, they never rewrite the close.
  //
  // **Validates: Requirements R-HOME-004, R-PLAN-003, R-HABIT-005**
  group(
    '[TEST-INSIGHT-AS-OF-CLOSE-PROP][MVP][TASK-8.1][R-PLAN-003,R-HABIT-005] '
    'as-of-close immutability',
    () {
      test(
        'appended adjustments never change the sealed values or version',
        () async {
          final PlannerTaskCloseTally sealed = tally(eligible: 5, completed: 2);
          const List<PlannerHabitCloseOutcome> habits =
              <PlannerHabitCloseOutcome>[
                PlannerHabitCloseOutcome(
                  occurrenceId: 'h1',
                  statusWire: 'completed',
                ),
                PlannerHabitCloseOutcome(
                  occurrenceId: 'h2',
                  statusWire: 'missed',
                ),
              ];

          DailySummary? baseline;
          for (int adjustments = 0; adjustments < 25; adjustments += 1) {
            final DailySummary result = (await summarize(
              serviceFor(
                snapshot(
                  tasks: sealed,
                  habits: habits,
                  adjustmentCount: adjustments,
                  watermark: 777,
                ),
              ),
            ))!;
            baseline ??= result;
            // Sealed task/habit values are identical no matter how many
            // adjustments were appended after close.
            expect(result.taskCompletion, baseline.taskCompletion);
            expect(result.habits.completed, baseline.habits.completed);
            expect(result.habits.missed, baseline.habits.missed);
            expect(result.metricPolicyVersion, 'metric-policy-v1');
            expect(result.sourceWatermarkCommitSeq, 777);
            expect(result.adjustmentCount, adjustments);
          }
        },
      );
    },
  );

  // Property: focus + study time is unioned so overlapping time is counted
  // once. The summary's combined seconds equal the interval-union of both span
  // sets and never their naive sum.
  //
  // **Validates: Requirements R-HOME-004, R-INSIGHT-001, R-FOCUS-005**
  group(
    '[TEST-INSIGHT-DAILY-INTERVAL-UNION-PROP][MVP][TASK-8.1][R-HOME-004,R-INSIGHT-001] '
    'interval-union',
    () {
      List<TimeSpan> randomSpans(Random random, int count) => <TimeSpan>[
        for (int i = 0; i < count; i += 1)
          () {
            final int start = random.nextInt(1000);
            return span(start, start + random.nextInt(120));
          }(),
      ];

      test(
        'combined time is the union of focus and study, never their sum',
        () async {
          for (final int seed in <int>[5, 13, 88, 4242]) {
            final Random random = Random(seed);
            for (int i = 0; i < 80; i += 1) {
              final List<TimeSpan> focus = randomSpans(
                random,
                random.nextInt(5),
              );
              final List<TimeSpan> study = randomSpans(
                random,
                random.nextInt(5),
              );
              final DailySummary result = (await summarize(
                serviceFor(snapshot(), focus: focus, study: study),
              ))!;

              final int expectedUnion = IntervalUnion.unionSeconds(<TimeSpan>[
                ...focus,
                ...study,
              ]);
              expect(result.combinedFocusStudySeconds, expectedUnion);
              expect(result.focusStudyOverlapSeconds, greaterThanOrEqualTo(0));
            }
          }
        },
      );
    },
  );
}
