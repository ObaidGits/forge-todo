import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/presentation/task_list_screen.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import 'tasks_widget_harness.dart';

/// Golden test protecting the task list's visual contract (testing.md §6).
///
/// **Validates: Requirements R-TASK-002, NFR-A11Y-003**
void main() {
  testWidgets('task list Today view — compact light golden', (
    WidgetTester tester,
  ) async {
    final TasksWidgetHarness h = await TasksWidgetHarness.open();
    addTearDown(h.close);

    await h.createTask(title: 'File taxes', due: TaskDue.onDate('2024-06-10'));
    await h.createTask(
      title: 'Prepare standup notes',
      due: TaskDue.onDate('2024-06-15'),
      priority: TaskPriority.high,
    );

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tasksProfileProvider.overrideWithValue(h.profileId),
          tasksQueryServiceProvider.overrideWithValue(h.query),
          tasksCommandServiceProvider.overrideWithValue(h.commands),
          tasksRecurrenceServiceProvider.overrideWithValue(h.recurrence),
          tasksDeletionServiceProvider.overrideWithValue(h.deletion),
          tasksPurgePreviewServiceProvider.overrideWithValue(h.preview),
          tasksClockProvider.overrideWithValue(h.clock),
          tasksCommandIdFactoryProvider.overrideWithValue(h.nextCommandId),
          tasksAreaOptionsProvider.overrideWithValue(<TaskAreaOption>[
            TaskAreaOption(id: h.lifeAreaId, name: 'Career'),
          ]),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: ThemeData(useMaterial3: true, fontFamily: 'Ahem'),
          home: const Scaffold(
            body: TaskListScreen(initialView: TaskListView.today),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(TaskListScreen),
      matchesGoldenFile('goldens/task_list_today_compact.png'),
    );
  });
}
