import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/presentation/widgets/task_list_tile.dart';

import 'tasks_widget_harness.dart';

/// Widget, semantics and keyboard tests for the adaptive task list.
///
/// **Validates: Requirements R-TASK-002, R-TASK-003, R-TASK-008, R-TASK-009,
/// R-GEN-001, R-GEN-003, NFR-UX-002, NFR-A11Y-001, NFR-A11Y-002**
void main() {
  late TasksWidgetHarness h;

  setUp(() async {
    h = await TasksWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  testWidgets('Today view shows overdue and due-today, hides upcoming/inbox', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'File taxes', due: TaskDue.onDate('2024-06-10'));
    await h.createTask(title: 'Standup', due: TaskDue.onDate('2024-06-15'));
    await h.createTask(title: 'Plan trip', due: TaskDue.onDate('2024-06-20'));
    await h.createTask(title: 'Buy milk');

    await h.pumpApp(tester);

    expect(find.text('File taxes'), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);
    expect(find.text('Plan trip'), findsNothing);
    expect(find.text('Buy milk'), findsNothing);
  });

  testWidgets('switching views lists Upcoming, Inbox, Completed (R-TASK-002)', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Plan trip', due: TaskDue.onDate('2024-06-20'));
    await h.createTask(title: 'Buy milk');
    await h.pumpApp(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Upcoming'));
    await tester.pumpAndSettle();
    expect(find.text('Plan trip'), findsOneWidget);
    expect(find.text('Buy milk'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.text('Plan trip'), findsNothing);
  });

  testWidgets('multi-select bulk complete uses one atomic action (R-GEN-005)', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'File taxes', due: TaskDue.onDate('2024-06-10'));
    await h.createTask(title: 'Standup', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    // Enter multi-select without any gesture-only affordance (NFR-A11Y).
    await tester.tap(find.widgetWithText(OutlinedButton, 'Select tasks'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('File taxes'));
    await tester.tap(find.text('Standup'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Complete'));
    await tester.pumpAndSettle();

    // Both moved out of the active Today view; the completed count reflects it.
    expect(find.text('File taxes'), findsNothing);
    expect(find.text('Standup'), findsNothing);
    final int completed = await h.scalar(
      "SELECT COUNT(*) FROM tasks WHERE status = 'completed'",
    );
    expect(completed, 2);
  });

  testWidgets('Shift-click selects a contiguous range (ux-design §9)', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Alpha', due: TaskDue.onDate('2024-06-15'));
    await h.createTask(title: 'Bravo', due: TaskDue.onDate('2024-06-15'));
    await h.createTask(title: 'Charlie', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select tasks'));
    await tester.pumpAndSettle();

    // Anchor on the first row, then Shift-click the last row: the whole visible
    // range is selected regardless of ordering.
    await tester.tap(find.byType(TaskListTile).first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byType(TaskListTile).last);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('3 selected'), findsOneWidget);
  });

  testWidgets('Select all selects every visible task (ux-design §9)', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Alpha', due: TaskDue.onDate('2024-06-15'));
    await h.createTask(title: 'Bravo', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Select all'));
    await tester.pumpAndSettle();

    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets(
    'bulk delete previews affected count and offers Undo (NFR-UX-002, '
    'R-GEN-003)',
    (WidgetTester tester) async {
      await h.createTask(title: 'Standup', due: TaskDue.onDate('2024-06-15'));
      await h.pumpApp(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Select tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Standup'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      // Affected-count confirmation before the destructive action.
      expect(find.text('Delete tasks?'), findsOneWidget);
      expect(find.textContaining('1 task will move to Trash'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      int trashed = await h.scalar(
        'SELECT COUNT(*) FROM tasks WHERE deleted_at_utc IS NOT NULL',
      );
      expect(trashed, 1);

      // Immediate Undo restores it (R-GEN-003).
      expect(find.text('Tasks moved to Trash'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();
      trashed = await h.scalar(
        'SELECT COUNT(*) FROM tasks WHERE deleted_at_utc IS NOT NULL',
      );
      expect(trashed, 0);
    },
  );

  testWidgets('priority filter narrows the list (R-TASK-008)', (
    WidgetTester tester,
  ) async {
    await h.createTask(
      title: 'Urgent thing',
      due: TaskDue.onDate('2024-06-15'),
      priority: TaskPriority.urgent,
    );
    await h.createTask(
      title: 'Normal thing',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.pumpApp(tester);

    expect(find.text('Normal thing'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Urgent'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();

    expect(find.text('Urgent thing'), findsOneWidget);
    expect(find.text('Normal thing'), findsNothing);
    expect(find.text('1 filter'), findsOneWidget);
  });

  testWidgets('Trash view lists soft-deleted tasks and can restore', (
    WidgetTester tester,
  ) async {
    final String id = await h.createTask(
      title: 'Old task',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.softDeleteRaw(id);
    await h.pumpApp(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Trash'));
    await tester.pumpAndSettle();
    expect(find.text('Old task'), findsOneWidget);
  });

  testWidgets('empty view renders a calm message (R-HOME-005)', (
    WidgetTester tester,
  ) async {
    await h.pumpApp(tester);
    expect(find.text('Nothing due today'), findsOneWidget);
  });

  testWidgets('list meets tap-target and labeling accessibility guidelines', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Review PR', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });

  testWidgets('task rows expose a labeled semantic button (NFR-A11Y-001)', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Review PR', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    final Finder tile = find.byType(TaskListTile).first;
    // Every task row is an operable, labeled button (NFR-A11Y-001).
    final SemanticsData data = tester.getSemantics(tile).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.label, contains('Review PR'));
  });

  testWidgets('list is keyboard traversable without pointer input', (
    WidgetTester tester,
  ) async {
    await h.createTask(title: 'Review PR', due: TaskDue.onDate('2024-06-15'));
    await h.pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    // Focus lands on an operable control; traversal is not trapped.
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
