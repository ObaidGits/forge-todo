import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/presentation/insights_providers.dart';
import 'package:forge/features/insights/presentation/insights_screen.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the Insights screen (R-INSIGHT-001..005, NFR-A11Y).
///
/// The screen renders the current weekly Insight as a chart plus its always
/// present text/table alternative, exposing every figure's numerator/
/// denominator and rendering a zero-denominator metric as "no data" rather than
/// a misleading 0%. When the compute stack is not wired it shows a calm
/// not-available empty state. The compute service is the real
/// [PeriodInsightsService] over faked application contracts, so the test
/// exercises the true composition path (design.md §4).
void main() {
  const Widget app = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: InsightsScreen()),
  );

  testWidgets('given_not_wired_when_opened_then_shows_not_available_state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: app));
    await tester.pumpAndSettle();

    expect(find.text("Insights aren't available yet."), findsOneWidget);
  });

  testWidgets('given_wired_when_opened_then_renders_table_with_data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          insightsProfileProvider.overrideWithValue(ProfileId('profile-1')),
          insightsLifeAreaProvider.overrideWithValue(LifeAreaId('area-1')),
          insightsClockProvider.overrideWithValue(_FixedClock()),
          insightsServiceProvider.overrideWithValue(
            _service(<PlannerDailyCloseSnapshot>[_close(eligible: 4, done: 3)]),
          ),
        ],
        child: app,
      ),
    );
    await tester.pumpAndSettle();

    // The reused accessible data table renders with explainable figures.
    expect(
      find.byKey(const ValueKey<String>('insight-data-table')),
      findsOneWidget,
    );
    expect(find.text('Task completion'), findsOneWidget);
    expect(find.text('75% (3/4)'), findsOneWidget);
    // Both period options are offered.
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
  });

  testWidgets('given_zero_denominator_when_opened_then_shows_no_data_not_zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          insightsProfileProvider.overrideWithValue(ProfileId('profile-1')),
          insightsLifeAreaProvider.overrideWithValue(LifeAreaId('area-1')),
          insightsClockProvider.overrideWithValue(_FixedClock()),
          insightsServiceProvider.overrideWithValue(
            // No factual closes in the window: task/habit metrics are no-data.
            _service(const <PlannerDailyCloseSnapshot>[]),
          ),
        ],
        child: app,
      ),
    );
    await tester.pumpAndSettle();

    // A zero-denominator metric never renders a misleading 0% (R-INSIGHT-002).
    expect(find.text('No data'), findsWidgets);
    expect(find.text('0% (0/0)'), findsNothing);
  });
}

/// A real compute service over faked, in-memory application contracts.
PeriodInsightsService _service(List<PlannerDailyCloseSnapshot> closes) =>
    PeriodInsightsService(
      plannerSummary: _FakePlannerSummary(closes),
      combinedTime: const CombinedTimeMetricsService(
        focusDuration: _EmptyFocusDuration(),
        studyDuration: _EmptyStudyDuration(),
      ),
      cache: _NullCache(),
      clock: _FixedClock(),
    );

PlannerDailyCloseSnapshot _close({required int eligible, required int done}) =>
    PlannerDailyCloseSnapshot(
      periodId: 'p-1',
      closedAtUtc: 0,
      boundaryUtc: 0,
      metricPolicyNumber: 1,
      sourceWatermarkCommitSeq: 1,
      tasks: PlannerTaskCloseTally(
        eligibleCount: eligible,
        completedCount: done,
        missedCount: 0,
        carriedCount: 0,
        eligibleRootHash: 'e',
        completedRootHash: 'c',
      ),
      habits: const <PlannerHabitCloseOutcome>[],
      adjustmentCount: 0,
    );

final class _FakePlannerSummary implements PlannerSummaryContract {
  const _FakePlannerSummary(this._closes);

  final List<PlannerDailyCloseSnapshot> _closes;

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async => _closes.isEmpty ? null : _closes.first;

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async => _closes;
}

final class _EmptyFocusDuration implements FocusDurationContract {
  const _EmptyFocusDuration();

  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => const <TimeSpan>[];
}

final class _EmptyStudyDuration implements StudyDurationContract {
  const _EmptyStudyDuration();

  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => const <TimeSpan>[];
}

final class _NullCache implements AggregateCacheStore {
  @override
  Future<CachedAggregate?> read(
    String profileId, {
    required String cacheKey,
  }) async => null;

  @override
  Future<void> write(CachedAggregate entry) async {}
}

final class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime utcNow() => DateTime.utc(2024, 3, 14, 12);

  @override
  String timezoneId() => 'UTC';
}
