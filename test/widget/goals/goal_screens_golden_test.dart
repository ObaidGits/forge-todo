import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/goals/presentation/roadmap_outline_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import 'goals_widget_harness.dart';

/// Golden test protecting the roadmap outline's visual contract (testing.md §6):
/// the transparent progress card, per-section aggregation, and keyboard reorder
/// controls at a compact width.
///
/// **Validates: Requirements R-GOAL-003, R-GOAL-004, R-GOAL-005, NFR-A11Y-003**
void main() {
  testWidgets('roadmap outline — compact light golden', (
    WidgetTester tester,
  ) async {
    final GoalsWidgetHarness h = await GoalsWidgetHarness.open();
    addTearDown(h.close);

    final String goalId = await h.createGoal(
      title: 'Learn Rust',
      progressMode: GoalProgressMode.derived,
    );
    final String roadmapId = await h.createRoadmap(goalId, title: 'Rust path');
    final String s1 = await h.addSection(roadmapId, title: 'Fundamentals');
    await h.addTopic(s1, title: 'Ownership', weight: 2);
    await h.addTopic(s1, title: 'Borrowing', weight: 1);

    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goalsProfileProvider.overrideWithValue(h.profileId),
          goalsRepositoryProvider.overrideWithValue(h.goalReads),
          roadmapRepositoryProvider.overrideWithValue(h.roadmapReads),
          goalsCommandServiceProvider.overrideWithValue(h.goals),
          roadmapCommandServiceProvider.overrideWithValue(h.roadmaps),
          goalsCommandIdFactoryProvider.overrideWithValue(h.nextCommandId),
          goalsAreaOptionsProvider.overrideWithValue(<GoalAreaOption>[
            GoalAreaOption(id: h.lifeAreaId, name: 'Career'),
          ]),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: ThemeData(useMaterial3: true, fontFamily: 'Ahem'),
          home: Scaffold(body: RoadmapOutlineScreen(goalId: goalId)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(RoadmapOutlineScreen),
      matchesGoldenFile('goldens/roadmap_outline_compact.png'),
    );
  });
}
