import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'learning_widget_harness.dart';

/// Widget tests for the Learn list (R-LEARN-001, R-LEARN-004, NFR-A11Y-001/003).
///
/// The Learn tab renders real Learning Resources instead of the placeholder,
/// creates resources title-first with a type, and navigates into the resource
/// screen where items and progress are shown.
void main() {
  late LearningWidgetHarness harness;

  setUp(() async {
    harness = await LearningWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_no_resources_when_opened_then_shows_empty_state', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    expect(
      find.text(
        "No learning resources yet. Add one to start tracking what you're "
        'learning.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('given_resources_when_opened_then_lists_them_with_progress', (
    WidgetTester tester,
  ) async {
    final String id = await harness.createResource(title: 'Rust Book');
    await harness.addItem(id, title: 'Ownership');
    await harness.pumpApp(tester);

    expect(find.text('Rust Book'), findsOneWidget);
    // Type, status and derived progress are surfaced as text (never color-only).
    expect(find.textContaining('Course'), findsWidgets);
    expect(find.textContaining('0% complete'), findsWidgets);
  });

  testWidgets('given_create_dialog_when_confirmed_then_navigates_to_resource', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New resource'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Clean Architecture');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // Landed on the resource screen for the new resource.
    expect(find.text('Clean Architecture'), findsWidgets);
    expect(find.text('Items'), findsOneWidget);
    expect(find.text('Start studying'), findsOneWidget);
  });

  testWidgets('given_resource_with_item_when_completed_then_progress_updates', (
    WidgetTester tester,
  ) async {
    final String id = await harness.createResource(title: 'Algorithms');
    await harness.addItem(id, title: 'Sorting');
    await harness.pumpApp(tester, initialLocation: '/learn/$id');

    expect(find.text('Not started'), findsNothing);
    expect(find.textContaining('0% complete'), findsWidgets);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.textContaining('100% complete'), findsWidgets);
  });
}
