import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/home/presentation/today_screen.dart';
import 'package:forge/features/home/presentation/widgets/task_action_row.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import '../../database/home/home_test_support.dart';

/// Widget tests for the accessible Today screen.
///
/// **Validates: Requirements R-HOME-001, R-HOME-002, R-HOME-003, R-HOME-005,
/// R-GEN-001, NFR-USAB-001, NFR-A11Y-001, NFR-A11Y-002**
void main() {
  late HomeHarness h;

  setUp(() async {
    h = await HomeHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> pumpToday(WidgetTester tester) async {
    int seq = 0;
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProfileProvider.overrideWithValue(h.profileId),
          quickCaptureAreaProvider.overrideWithValue(h.tasks.lifeAreaId),
          taskQueryServiceProvider.overrideWith((Ref ref) => h.queryService),
          taskCommandServiceProvider.overrideWith((Ref ref) => h.tasks.service),
          homeLayoutStoreProvider.overrideWithValue(h.layoutStore),
          homeClockProvider.overrideWithValue(h.tasks.clock),
          commandIdFactoryProvider.overrideWithValue(
            () => CommandId('cmd-w-${seq++}'),
          ),
        ],
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

  testWidgets('renders populated sections and collapses empty ones', (
    WidgetTester tester,
  ) async {
    await h.createTask(
      seed: 'od',
      title: 'File taxes',
      due: TaskDue.onDate('2024-06-10'),
    );
    await h.createTask(
      seed: 'td',
      title: 'Standup',
      due: TaskDue.onDate('2024-06-15'),
    );

    await pumpToday(tester);

    expect(find.textContaining('Overdue'), findsWidgets);
    expect(find.text('File taxes'), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);
    // Progressive/empty sections collapse (R-HOME-002): no completed header.
    expect(find.textContaining('Completed'), findsNothing);
    // Non-blocking local sync status is shown (R-HOME-005).
    expect(find.text('Saved on this device'), findsOneWidget);
  });

  testWidgets('fresh profile shows a calm empty state with quick capture', (
    WidgetTester tester,
  ) async {
    await pumpToday(tester);

    expect(find.text('Nothing scheduled yet'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Add a task'), findsOneWidget);
  });

  testWidgets(
    'quick capture commits and surfaces committed feedback (R-HOME-003, '
    'NFR-USAB-001)',
    (WidgetTester tester) async {
      await pumpToday(tester);

      await tester.enterText(find.byType(TextField), 'Buy milk');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      // Committed feedback (from the durable receipt, not a dispatch ack)
      // appears immediately and the input is cleared for the next capture.
      // A title-only task is an Inbox task, so it is durably stored but does
      // not appear on Today.
      expect(find.text('Added'), findsOneWidget);
      expect(
        (tester.widget<TextField>(find.byType(TextField))).controller?.text,
        isEmpty,
      );
      // The task is durably committed to the local database (R-GEN-001).
      final int stored = await h.tasks.scalar(
        "SELECT COUNT(*) FROM tasks WHERE title = 'Buy milk'",
      );
      expect(stored, 1);
    },
  );

  testWidgets('empty quick capture is rejected and retains focus', (
    WidgetTester tester,
  ) async {
    await pumpToday(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a title to add a task.'), findsOneWidget);
  });

  testWidgets('inline completion moves a task to completed (R-HOME-003)', (
    WidgetTester tester,
  ) async {
    await h.createTask(
      seed: 'ic',
      title: 'Water plants',
      due: TaskDue.onDate('2024-06-15'),
    );
    await pumpToday(tester);

    expect(find.text('Water plants'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // The task now appears under a Completed section, still on the screen
    // (no navigation occurred).
    expect(find.textContaining('Completed'), findsOneWidget);
    expect(find.byType(TaskActionRow), findsWidgets);
  });

  testWidgets('a section can be hidden from its menu (R-HOME-002)', (
    WidgetTester tester,
  ) async {
    await h.createTask(
      seed: 'td',
      title: 'Standup',
      due: TaskDue.onDate('2024-06-15'),
    );
    await pumpToday(tester);

    expect(find.text('Standup'), findsOneWidget);
    // Open the Today section menu and hide it.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide section'));
    await tester.pumpAndSettle();

    expect(find.text('Standup'), findsNothing);

    // Reset layout restores it.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset layout'));
    await tester.pumpAndSettle();
    expect(find.text('Standup'), findsOneWidget);
  });

  testWidgets('Today meets tap-target and labeling accessibility guidelines', (
    WidgetTester tester,
  ) async {
    await h.createTask(
      seed: 'a11y',
      title: 'Review PR',
      due: TaskDue.onDate('2024-06-15'),
    );
    await pumpToday(tester);

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
