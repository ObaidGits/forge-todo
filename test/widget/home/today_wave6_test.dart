import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/composition/home_feature_composition.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/home/presentation/today_screen.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import '../../database/home/wave6_home_integration_support.dart';

/// Widget tests for the Wave 6 Today surfaces: habit checklist, study resume,
/// and focus, wired through the composition-root [homeFeatureOverrides].
///
/// **Validates: Requirements R-HOME-001, R-HOME-002, R-HOME-003, R-HOME-005**
///
/// Evidence: [TEST-WIDGET-HOME-WAVE6][MVP][TASK-7.5]
void main() {
  late Wave6HomeHarness h;

  setUp(() async {
    h = await Wave6HomeHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> pumpToday(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      HomeFeatureScope(
        profileId: h.profileId,
        quickCaptureArea: h.lifeAreaId,
        clock: h.clock,
        layoutStore: h.layoutStore,
        taskQuery: h.taskQuery,
        taskCommands: h.tasks,
        learningResume: h.learningReads,
        habitQuery: h.habitQuery,
        habitCommands: h.habits,
        focusContract: h.focusReads,
        focusCommands: h.focus,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          home: const Scaffold(body: TodayScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renders habit, focus, and study sections together (R-HOME-001)',
    (WidgetTester tester) async {
      await h.createTask('Standup', due: TaskDue.onDate('2024-06-15'));
      await h.createDailyHabit('Meditate', seed: 'habit-med');
      await h.createResumableResource('Algorithms');
      await h.startFocus(seed: 'focus-1');

      await pumpToday(tester);

      expect(find.text('Meditate'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('focus-active-tile')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('resume-learning-tile')),
        findsOneWidget,
      );
      expect(find.text('Algorithms'), findsOneWidget);
    },
  );

  testWidgets(
    'inline boolean habit check-in completes it on Today (R-HOME-003)',
    (WidgetTester tester) async {
      await h.createDailyHabit('Meditate', seed: 'habit-med');
      await pumpToday(tester);

      expect(find.byType(Checkbox), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      // The occurrence is durably completed in the local database (R-GEN-001).
      final int completed = await h.scalar(
        "SELECT COUNT(*) FROM habit_occurrences WHERE status = 'completed'",
      );
      expect(completed, 1);
    },
  );

  testWidgets('the focus section offers to start a session and starts it '
      '(R-HOME-003)', (WidgetTester tester) async {
    await pumpToday(tester);

    // With focus wired but no open session, the start affordance is shown.
    expect(
      find.byKey(const ValueKey<String>('focus-start-tile')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Start focus'));
    await tester.pumpAndSettle();

    final int open = await h.scalar(
      "SELECT COUNT(*) FROM focus_sessions "
      "WHERE status IN ('running','paused') AND deleted_at_utc IS NULL",
    );
    expect(open, 1);
    // The active session tile now replaces the start affordance.
    expect(
      find.byKey(const ValueKey<String>('focus-active-tile')),
      findsOneWidget,
    );
  });

  testWidgets('collapses habit/study/focus sections when nothing is present '
      '(R-HOME-002)', (WidgetTester tester) async {
    await h.createTask('Standup', due: TaskDue.onDate('2024-06-15'));
    await pumpToday(tester);

    expect(find.text('Standup'), findsOneWidget);
    // The habit checklist and study slots collapse when empty (R-HOME-002):
    // no Habits section header and no resume-learning tile are rendered. (The
    // focus section stays visible because focus is wired and offers to start a
    // session — that is intentional, not a collapsed slot.)
    expect(find.text('Habits'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('resume-learning-tile')),
      findsNothing,
    );
  });
}
