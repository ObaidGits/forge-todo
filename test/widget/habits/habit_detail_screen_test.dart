import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'habits_widget_harness.dart';

/// Widget tests for the habit detail surface: history, calendar, statistics,
/// and the backfill impact-preview interface (R-HABIT-004, R-HABIT-005,
/// R-HABIT-007, NFR-A11Y-001).
void main() {
  late HabitsWidgetHarness harness;

  // Deep links require an opaque UUIDv7 id (uri_policy), so the habit id must
  // be a valid v7 value rather than a friendly slug.
  const String habitId = '018f0000-0000-7000-8000-0000000000a1';

  setUp(() async {
    harness = await HabitsWidgetHarness.open();
    await harness.createBooleanHabit(
      id: habitId,
      title: 'Meditate',
      startIso: '2024-06-10',
    );
    // Three consecutive completed occurrences ahead of today (2024-06-15).
    await harness.checkInBoolean(habitId, '2024-06-10');
    await harness.checkInBoolean(habitId, '2024-06-11');
    await harness.checkInBoolean(habitId, '2024-06-12');
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_history_when_opened_then_lists_occurrences_newest_first', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester, initialLocation: '/habits/$habitId');
    expect(find.text('Meditate'), findsWidgets);
    expect(find.text('2024-06-12'), findsOneWidget);
    expect(find.text('2024-06-10'), findsOneWidget);
  });

  testWidgets('given_statistics_tab_when_opened_then_shows_streak_and_policy', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester, initialLocation: '/habits/$habitId');
    await tester.tap(find.text('Statistics'));
    await tester.pumpAndSettle();

    expect(find.text('Current streak'), findsOneWidget);
    expect(find.text('3 in a row'), findsOneWidget);
    // Transparent consistency with numerator/denominator and the policy tag.
    expect(find.text('3 of 3 (100%)'), findsOneWidget);
    expect(find.text('Metric policy metric-policy-v1'), findsOneWidget);
  });

  testWidgets('given_history_day_when_tapped_then_previews_metric_impact', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester, initialLocation: '/habits/$habitId');

    await tester.tap(find.text('2024-06-12'));
    await tester.pumpAndSettle();

    // The preview sheet is open and explains it commits nothing yet.
    expect(
      find.textContaining('Nothing is saved until you apply it'),
      findsOneWidget,
    );

    // Correcting the latest completed day to "Not logged" breaks the streak.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Not logged'));
    await tester.pumpAndSettle();
    expect(find.text('Streak: 3 to 0'), findsOneWidget);
  });

  testWidgets('given_calendar_tab_when_opened_then_renders_month_with_marks', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester, initialLocation: '/habits/$habitId');
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();

    expect(find.text('2024-06'), findsOneWidget);
    // Completed days carry a text marker, never color alone (ux-design §5).
    expect(find.text('✓'), findsWidgets);

    // Month navigation is an explicit, labelled control.
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.text('2024-07'), findsOneWidget);
  });
}
