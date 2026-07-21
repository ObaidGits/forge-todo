import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';
import 'package:forge/features/habits/presentation/widgets/habit_statistics_card.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the statistics card's transparent metric surface
/// (R-HABIT-007): the "no eligible data" state and the policy version tag.
Future<void> _pumpCard(WidgetTester tester, HabitStatistics statistics) {
  return tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: HabitStatisticsCard(statistics: statistics)),
    ),
  );
}

void main() {
  testWidgets('given_zero_denominator_then_shows_no_eligible_data_not_zero', (
    WidgetTester tester,
  ) async {
    await _pumpCard(
      tester,
      const HabitStatistics(
        currentStreak: 0,
        consistency: HabitConsistency(completed: 0, denominator: 0),
        fromIso: '2023-06-15',
        toIso: '2024-06-15',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No eligible data'), findsOneWidget);
    // Never a misleading 0% for an empty denominator (R-HABIT-007).
    expect(find.textContaining('0%'), findsNothing);
    // Always names the displayed metric-policy version.
    expect(find.text('Metric policy metric-policy-v1'), findsOneWidget);
  });

  testWidgets('given_data_then_shows_transparent_numerator_over_denominator', (
    WidgetTester tester,
  ) async {
    await _pumpCard(
      tester,
      const HabitStatistics(
        currentStreak: 2,
        consistency: HabitConsistency(completed: 2, denominator: 4),
        fromIso: '2024-06-01',
        toIso: '2024-06-15',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 in a row'), findsOneWidget);
    expect(find.text('2 of 4 (50%)'), findsOneWidget);
  });
}
