import 'package:flutter_test/flutter_test.dart';

import 'learning_widget_harness.dart';

/// Widget tests for the per-item Learn detail (`/learn/:resourceId/item/:itemId`)
/// (R-LEARN-001, R-LEARN-002, R-LEARN-004, NFR-A11Y-001/003).
///
/// The item route renders a real item screen (its title, type, and completion)
/// instead of the routing placeholder, and reuses the learning command service
/// to complete/reopen the item, with a calm not-found state for an unknown id.
void main() {
  late LearningWidgetHarness harness;

  setUp(() async {
    harness = await LearningWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets('given_item_when_opened_then_shows_title_type_and_status', (
    WidgetTester tester,
  ) async {
    final String resourceId = await harness.createResource(title: 'Rust Book');
    final String itemId = await harness.addItem(resourceId, title: 'Ownership');
    await harness.pumpApp(
      tester,
      initialLocation: '/learn/$resourceId/item/$itemId',
    );

    expect(find.text('Ownership'), findsOneWidget);
    expect(find.textContaining('Lesson'), findsOneWidget);
    expect(find.textContaining('Not completed'), findsOneWidget);
    expect(find.text('Mark complete'), findsOneWidget);
  });

  testWidgets('given_item_when_marked_complete_then_status_flips', (
    WidgetTester tester,
  ) async {
    final String resourceId = await harness.createResource(title: 'Algorithms');
    final String itemId = await harness.addItem(resourceId, title: 'Sorting');
    await harness.pumpApp(
      tester,
      initialLocation: '/learn/$resourceId/item/$itemId',
    );

    await tester.tap(find.text('Mark complete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Completed'), findsOneWidget);
    expect(find.text('Reopen'), findsOneWidget);
  });

  testWidgets('given_unknown_item_when_opened_then_shows_not_found', (
    WidgetTester tester,
  ) async {
    final String resourceId = await harness.createResource(title: 'Networking');
    // A syntactically valid opaque id that addresses no real item, so the URI
    // policy admits the route and the screen renders its own not-found state.
    const String missingItemId = '0190aaaa-0000-7000-8000-000000000000';
    await harness.pumpApp(
      tester,
      initialLocation: '/learn/$resourceId/item/$missingItemId',
    );

    expect(find.text('This item could not be found.'), findsOneWidget);
  });
}
