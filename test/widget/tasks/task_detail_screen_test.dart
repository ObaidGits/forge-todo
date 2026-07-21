import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/domain/task_due.dart';

import 'tasks_widget_harness.dart';

/// Widget and semantics tests for the task detail screen.
///
/// **Validates: Requirements R-TASK-001, R-TASK-003, R-TASK-009, R-GEN-003,
/// NFR-A11Y-001**
void main() {
  late TasksWidgetHarness h;

  setUp(() async {
    h = await TasksWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  testWidgets('opening a task shows its fields and lifecycle actions', (
    WidgetTester tester,
  ) async {
    final String id = await h.createTask(
      title: 'Write report',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.pumpApp(tester, initialLocation: '/tasks/$id');

    expect(find.text('Write report'), findsWidgets);
    expect(find.text('Mark complete'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Cancel task'), findsOneWidget);
  });

  testWidgets('completing from detail is reversible (R-TASK-009)', (
    WidgetTester tester,
  ) async {
    final String id = await h.createTask(
      title: 'Write report',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.pumpApp(tester, initialLocation: '/tasks/$id');

    await tester.tap(find.widgetWithText(FilledButton, 'Mark complete'));
    await tester.pumpAndSettle();

    final int completed = await h.scalar(
      "SELECT COUNT(*) FROM tasks WHERE status = 'completed'",
    );
    expect(completed, 1);
    // The reopen affordance now appears (reversible completion).
    expect(find.text('Mark not complete'), findsOneWidget);
  });

  testWidgets('deleting from detail soft-deletes and offers Undo (R-GEN-003)', (
    WidgetTester tester,
  ) async {
    final String id = await h.createTask(
      title: 'Write report',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.pumpApp(tester, initialLocation: '/tasks/$id');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();

    final int trashed = await h.scalar(
      'SELECT COUNT(*) FROM tasks WHERE deleted_at_utc IS NOT NULL',
    );
    expect(trashed, 1);
    expect(find.text('Task moved to Trash'), findsOneWidget);
  });

  testWidgets('an unknown task shows a recoverable not-found state', (
    WidgetTester tester,
  ) async {
    await h.pumpApp(
      tester,
      initialLocation: '/tasks/018f0000-0000-7000-8000-0000deadbeef',
    );
    expect(find.text('This task could not be found.'), findsOneWidget);
  });

  testWidgets('detail meets accessibility guidelines', (
    WidgetTester tester,
  ) async {
    final String id = await h.createTask(
      title: 'Write report',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.pumpApp(tester, initialLocation: '/tasks/$id');

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
