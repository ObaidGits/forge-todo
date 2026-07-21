import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/daily_summary_service.dart';
import 'package:forge/features/insights/domain/daily_summary.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_summary_repository.dart';

import '../planner/planner_test_support.dart';

/// Study contract returning fixed in-range spans for the combined metric.
final class _FixedStudy implements StudyDurationContract {
  _FixedStudy(this.spans);
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

/// Focus contract returning fixed in-range spans for the combined metric.
final class _FixedFocus implements FocusDurationContract {
  _FixedFocus(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => spans;
}

/// The Daily Summary composed over a real Drift-backed immutable factual close,
/// proving as-of-close immutability under later mutation (R-HOME-004,
/// R-PLAN-003, R-HABIT-005).
void main() {
  late PlannerHarness h;
  late DailySummaryService summaries;
  const int s = IntervalUnion.microsPerSecond;

  setUp(() async {
    h = await PlannerHarness.open();
    summaries = DailySummaryService(
      plannerSummary: PlannerSummaryRepository(h.reads),
      combinedTime: CombinedTimeMetricsService(
        // 09:00-10:00 focus overlapping 09:30-10:30 study => union 5400s.
        focusDuration: _FixedFocus(<TimeSpan>[
          TimeSpan(startUtc: 0, endUtc: 3600 * s),
        ]),
        studyDuration: _FixedStudy(<TimeSpan>[
          TimeSpan(startUtc: 1800 * s, endUtc: 5400 * s),
        ]),
      ),
    );
  });

  tearDown(() async {
    await h.close();
  });

  Future<PlanningPeriod> saveDay(String key, {String? reflection}) async {
    await h.service.savePlanningRecord(
      commandId: h.nextCommandId('save-$key'),
      profileId: h.profileId,
      input: SavePlanningRecordInput(
        lifeAreaId: h.lifeAreaId.value,
        kind: PlanningPeriodKind.day,
        periodKey: key,
        dailyPlanMd: SectionEdit.set('plan $key'),
        eveningReflectionMd: reflection == null
            ? SectionEdit.unchanged
            : SectionEdit.set(reflection),
      ),
    );
    return (await h.reads.findByKey(
      h.profileId,
      lifeAreaId: h.lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: key,
    ))!;
  }

  Future<DailySummary?> summarize(String dayKey) => summaries.summarize(
    h.profileId,
    lifeAreaId: h.lifeAreaId,
    dayKey: dayKey,
    dayStartUtc: 0,
    dayEndUtc: 100000 * s,
  );

  test('[TEST-DB-INSIGHT-DAILY-SUMMARY][MVP][TASK-8.1][R-HOME-004] '
      'there is no summary before the day is closed, then one after', () async {
    await saveDay('2024-06-01', reflection: 'Solid start.');
    expect(await summarize('2024-06-01'), isNull);

    final PlanningPeriod day = (await h.reads.findByKey(
      h.profileId,
      lifeAreaId: h.lifeAreaId,
      kind: PlanningPeriodKind.day,
      periodKey: '2024-06-01',
    ))!;
    await h.service.closePeriod(
      commandId: h.nextCommandId('close-1'),
      profileId: h.profileId,
      input: ClosePeriodInput(
        periodId: day.id.value,
        boundaryUtc: 2_000_000,
        metricPolicyVersion: 1,
        tasks: const <CloseTaskInput>[
          // 'shared' is both planned AND due: set-union counts it once.
          CloseTaskInput(
            taskId: 'shared',
            isPlanned: true,
            isDue: true,
            completedAtOrBeforeBoundary: true,
          ),
          CloseTaskInput(
            taskId: 'planned-only',
            isPlanned: true,
            isDue: false,
            completedAtOrBeforeBoundary: false,
          ),
        ],
        habits: const <CloseHabitInput>[
          CloseHabitInput(occurrenceId: 'occ-done', status: 'completed'),
          CloseHabitInput(occurrenceId: 'occ-miss', status: 'missed'),
        ],
      ),
    );

    final DailySummary summary = (await summarize('2024-06-01'))!;
    // Set-union: two distinct eligible tasks, not three.
    expect(summary.taskCompletion.numerator, 1);
    expect(summary.taskCompletion.denominator, 2);
    expect(summary.habits.completed, 1);
    expect(summary.habits.missed, 1);
    // Interval-union of the fixed focus/study spans.
    expect(summary.combinedFocusStudySeconds, 5400);
    expect(summary.focusStudyOverlapSeconds, 1800);
    expect(summary.reflectionMd, 'Solid start.');
    expect(summary.metricPolicyVersion, 'metric-policy-v1');
    expect(summary.adjustmentCount, 0);
  });

  test(
    '[TEST-DB-INSIGHT-DAILY-SUMMARY-AS-OF-CLOSE][MVP][TASK-8.1][R-PLAN-003,R-HABIT-005] '
    'later source and policy adjustments never change the as-of-close summary',
    () async {
      final PlanningPeriod day = await saveDay('2024-06-02');
      await h.service.closePeriod(
        commandId: h.nextCommandId('close-2'),
        profileId: h.profileId,
        input: ClosePeriodInput(
          periodId: day.id.value,
          boundaryUtc: 1,
          metricPolicyVersion: 1,
          tasks: const <CloseTaskInput>[
            CloseTaskInput(
              taskId: 'task-missed',
              isPlanned: true,
              isDue: true,
              completedAtOrBeforeBoundary: false,
            ),
          ],
        ),
      );

      final DailySummary before = (await summarize('2024-06-02'))!;
      expect(before.taskCompletion.numerator, 0);
      expect(before.taskCompletion.denominator, 1);
      expect(before.adjustmentCount, 0);

      // Append a source correction: the task was completed late.
      await h.service.appendSourceCorrection(
        commandId: h.nextCommandId('src'),
        profileId: h.profileId,
        input: SourceCorrectionInput(
          periodId: day.id.value,
          affectedEntityType: 'task',
          affectedEntityId: 'task-missed',
          affectedMetric: 'task_completion',
          priorClassification: 'missed',
          currentClassification: 'completed',
          delta: 1,
        ),
      );
      // Append a newer-policy recomputation.
      await h.service.appendPolicyRecomputation(
        commandId: h.nextCommandId('pol'),
        profileId: h.profileId,
        input: PolicyRecomputationInput(
          periodId: day.id.value,
          metricPolicyVersion: 2,
          derivedSummaryJson: '{"task_completion":1.0}',
        ),
      );

      final DailySummary after = (await summarize('2024-06-02'))!;
      // The sealed factual close is unchanged: still 0/1 under metric-policy-v1.
      expect(after.taskCompletion, before.taskCompletion);
      expect(after.metricPolicyVersion, 'metric-policy-v1');
      expect(after.sourceWatermarkCommitSeq, before.sourceWatermarkCommitSeq);
      expect(after.eligibleRootHash, before.eligibleRootHash);
      // The adjustments are surfaced only as a count.
      expect(after.adjustmentCount, 2);
    },
  );
}
