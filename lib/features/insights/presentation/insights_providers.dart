import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/insight_trend.dart';
import 'package:forge/features/insights/domain/period_insight.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The insights
// feature owns its own seams so its presentation never imports another
// feature's presentation or infrastructure, and never touches insights
// infrastructure directly (design.md §4). The compute service composes only
// exported application contracts, so the presentation depends on the
// application + domain alone.
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> insightsProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The weekly/monthly Insight compute service. Null until wired.
final Provider<PeriodInsightsService?> insightsServiceProvider =
    Provider<PeriodInsightsService?>((Ref ref) => null);

/// A trusted UTC clock used to resolve the current week/month window.
final Provider<Clock> insightsClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// The Life Area the Insight is scoped to (R-INSIGHT-002 reports the filter
/// alongside every value). Null until wired, in which case Insights are shown
/// as not-configured.
final Provider<LifeAreaId?> insightsLifeAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Whether the insights compute stack is wired at all (used for the
/// not-configured distinction in the UI).
final Provider<bool> insightsConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(insightsProfileProvider) != null &&
      ref.watch(insightsServiceProvider) != null &&
      ref.watch(insightsLifeAreaProvider) != null;
});

// ---------------------------------------------------------------------------
// Period toggle (weekly / monthly).
// ---------------------------------------------------------------------------

/// The currently selected Insight window. Weekly and monthly are both V1
/// windows aggregated from the same immutable factual daily closes
/// (R-INSIGHT-001).
final class InsightPeriodController extends Notifier<InsightPeriodKind> {
  @override
  InsightPeriodKind build() => InsightPeriodKind.weekly;

  void select(InsightPeriodKind kind) {
    if (state != kind) {
      state = kind;
    }
  }
}

final NotifierProvider<InsightPeriodController, InsightPeriodKind>
insightPeriodProvider =
    NotifierProvider<InsightPeriodController, InsightPeriodKind>(
      InsightPeriodController.new,
    );

// ---------------------------------------------------------------------------
// Comparison projection (R-INSIGHT-001, R-INSIGHT-002, R-INSIGHT-004).
// ---------------------------------------------------------------------------

/// Computes the current weekly or monthly Insight for the active profile paired
/// with its trend against the comparable previous period (R-INSIGHT-002). Both
/// endpoints are aggregated from the immutable factual daily closes over the
/// resolved calendar window, so the value is reproducible and never a
/// cross-user benchmark (R-INSIGHT-004, R-INSIGHT-005). Focus/study time is
/// unioned so overlapping time is counted once (R-INSIGHT-001).
final class InsightComparisonController
    extends AsyncNotifier<PeriodInsightComparison?> {
  @override
  Future<PeriodInsightComparison?> build() async {
    final ProfileId? profile = ref.watch(insightsProfileProvider);
    final PeriodInsightsService? service = ref.watch(insightsServiceProvider);
    final LifeAreaId? area = ref.watch(insightsLifeAreaProvider);
    final Clock clock = ref.watch(insightsClockProvider);
    final InsightPeriodKind kind = ref.watch(insightPeriodProvider);
    if (profile == null || service == null || area == null) {
      return null;
    }

    final DateTime now = clock.utcNow();
    final String timezoneId = clock.timezoneId();
    final LocalDate anchor = LocalDate(now.year, now.month, now.day);

    final InsightPeriod current = _resolvePeriod(kind, anchor, timezoneId);
    final InsightPeriod previous = _resolvePeriod(
      kind,
      _previousAnchor(kind, anchor),
      timezoneId,
    );

    final PeriodInsight currentInsight = await service.insight(
      profile,
      current,
      lifeAreaId: area,
    );
    final PeriodInsight previousInsight = await service.insight(
      profile,
      previous,
      lifeAreaId: area,
    );
    return service.compare(currentInsight, previous: previousInsight);
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<
  InsightComparisonController,
  PeriodInsightComparison?
>
insightComparisonProvider =
    AsyncNotifierProvider<
      InsightComparisonController,
      PeriodInsightComparison?
    >(InsightComparisonController.new);

// ---------------------------------------------------------------------------
// Pure window arithmetic. Windows are derived from calendar arithmetic (no wall
// clock), so the same anchor date always yields the same window on every device
// and run (R-GEN-004).
// ---------------------------------------------------------------------------

/// The calendar anchor of the comparable previous window: one week earlier for
/// weekly, one month earlier for monthly.
LocalDate _previousAnchor(InsightPeriodKind kind, LocalDate anchor) =>
    switch (kind) {
      InsightPeriodKind.weekly => anchor.addDays(-7),
      InsightPeriodKind.monthly => anchor.addMonths(-1),
    };

/// Resolves the weekly or monthly [InsightPeriod] containing [anchor], with the
/// UTC-micros range bounds the interval-unioned focus/study time is read over.
InsightPeriod _resolvePeriod(
  InsightPeriodKind kind,
  LocalDate anchor,
  String timezoneId,
) {
  switch (kind) {
    case InsightPeriodKind.weekly:
      // Weeks start Monday, matching InsightPeriod.weekly's default.
      final int offset = ((anchor.weekday - DateTime.monday) % 7 + 7) % 7;
      final LocalDate start = anchor.addDays(-offset);
      final LocalDate end = start.addDays(7);
      return InsightPeriod.weekly(
        anchor,
        timezoneId: timezoneId,
        rangeStartUtc: _utcMicrosAtMidnight(start),
        rangeEndUtc: _utcMicrosAtMidnight(end),
      );
    case InsightPeriodKind.monthly:
      final LocalDate first = anchor.firstDayOfMonth;
      final LocalDate next = first.addMonths(1);
      return InsightPeriod.monthly(
        anchor,
        timezoneId: timezoneId,
        rangeStartUtc: _utcMicrosAtMidnight(first),
        rangeEndUtc: _utcMicrosAtMidnight(next),
      );
  }
}

/// The UTC-micros instant at the start of [date]. The clock is UTC, so a
/// calendar date maps directly to its UTC midnight; a future timezone-aware
/// clock would resolve the same date through its resolver instead.
int _utcMicrosAtMidnight(LocalDate date) =>
    DateTime.utc(date.year, date.month, date.day).microsecondsSinceEpoch;

/// A UTC system clock used until the composition root overrides it.
final class _SystemUtcClock implements Clock {
  const _SystemUtcClock();

  @override
  DateTime utcNow() => DateTime.now().toUtc();

  @override
  String timezoneId() => 'UTC';
}
