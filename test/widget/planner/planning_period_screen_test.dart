import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/presentation/planner_providers.dart';
import 'package:forge/features/planner/presentation/planning_period_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the planning-record deep link (`/planner/:planningPeriodId`)
/// (R-PLAN-001, R-PLAN-004, NFR-A11Y-001/003).
void main() {
  MaterialApp app(String id) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: PlanningPeriodScreen(periodId: id)),
  );

  Widget host({required String id, required PlanningPeriod? record}) =>
      ProviderScope(
        overrides: [
          plannerConfiguredProvider.overrideWithValue(true),
          plannerRecordProvider.overrideWith((Ref ref, String arg) async {
            return arg == id ? record : null;
          }),
        ],
        child: app(id),
      );

  PlanningPeriod dayRecord() => PlanningPeriod(
    id: PlanningPeriodId('per-day'),
    profileId: ProfileId('p1'),
    lifeAreaId: LifeAreaId('a1'),
    kind: PlanningPeriodKind.day,
    periodKey: '2024-06-15',
    morningPlanMd: 'Ship the router work',
    createdAtUtc: 0,
    updatedAtUtc: 0,
  );

  PlanningPeriod weekRecord() => PlanningPeriod(
    id: PlanningPeriodId('per-week'),
    profileId: ProfileId('p1'),
    lifeAreaId: LifeAreaId('a1'),
    kind: PlanningPeriodKind.week,
    periodKey: '2024-W25',
    planIntentionMd: 'Focus on routing',
    createdAtUtc: 0,
    updatedAtUtc: 0,
  );

  testWidgets('given_day_record_when_opened_then_renders_daily_sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(id: 'per-day', record: dayRecord()));
    await tester.pumpAndSettle();

    expect(find.text('Daily plan'), findsWidgets);
    expect(find.text('Morning plan'), findsOneWidget);
    expect(find.text('Evening reflection'), findsOneWidget);
    expect(find.text('Ship the router work'), findsOneWidget);
    expect(find.text('Period 2024-06-15'), findsOneWidget);
  });

  testWidgets('given_week_record_when_opened_then_renders_aggregate_sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(id: 'per-week', record: weekRecord()));
    await tester.pumpAndSettle();

    expect(find.text('Weekly plan'), findsOneWidget);
    expect(find.text('Plan & intention'), findsOneWidget);
    expect(find.text('Reflection'), findsOneWidget);
    expect(find.text('Focus on routing'), findsOneWidget);
    // Aggregate records do not render the daily-only sections.
    expect(find.text('Morning plan'), findsNothing);
  });

  testWidgets('given_unknown_record_when_opened_then_shows_not_found', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(id: 'missing', record: null));
    await tester.pumpAndSettle();

    expect(
      find.text('This planning record could not be found.'),
      findsOneWidget,
    );
  });
}
