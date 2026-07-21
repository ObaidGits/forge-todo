import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tasks_widget_harness.dart';

/// Widget tests for the progressive-disclosure task editor.
///
/// **Validates: Requirements R-TASK-001, R-TASK-003, R-TASK-004, R-GEN-001,
/// NFR-A11Y-001**
void main() {
  late TasksWidgetHarness h;

  setUp(() async {
    h = await TasksWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> openEditor(WidgetTester tester) async {
    await h.pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New task'));
    await tester.pumpAndSettle();
  }

  testWidgets('editor opens with title first and options hidden (fast path)', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);

    expect(find.widgetWithText(TextFormField, 'Title'), findsOneWidget);
    // Advanced fields are progressively disclosed, not shown by default.
    expect(find.text('Priority'), findsNothing);
    expect(find.text('More options'), findsOneWidget);
  });

  testWidgets('empty title is rejected with a specific message', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a title.'), findsOneWidget);
  });

  testWidgets('title-only save commits durably and returns (R-TASK-001)', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'Draft proposal',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final int stored = await h.scalar(
      "SELECT COUNT(*) FROM tasks WHERE title = 'Draft proposal'",
    );
    expect(stored, 1);
  });

  testWidgets('progressive disclosure reveals advanced fields', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);

    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();

    expect(find.text('Priority'), findsWidgets);
    expect(find.text('Life Area'), findsWidgets);
    expect(find.text('Repeat'), findsWidgets);
  });

  testWidgets('editing a dated due persists the date (R-TASK-004)', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'Submit form',
    );
    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On a date'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Date (YYYY-MM-DD)'),
      '2024-07-01',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final int stored = await h.scalar(
      "SELECT COUNT(*) FROM tasks "
      "WHERE title = 'Submit form' AND due_date = '2024-07-01'",
    );
    expect(stored, 1);
  });

  testWidgets('editor meets accessibility guidelines', (
    WidgetTester tester,
  ) async {
    await openEditor(tester);
    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
