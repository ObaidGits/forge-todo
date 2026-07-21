import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';

import 'search_widget_harness.dart';

/// Widget tests for global search (R-SEARCH-001, R-SEARCH-002, R-SEARCH-003,
/// NFR-A11Y-001).
void main() {
  late SearchWidgetHarness harness;

  setUp(() async {
    harness = await SearchWidgetHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).first, query);
    await tester.pumpAndSettle();
  }

  testWidgets('given_empty_query_when_opened_then_shows_prompt', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    expect(find.textContaining('Start typing to search'), findsOneWidget);
  });

  testWidgets('given_query_when_typed_then_shows_grouped_results', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await type(tester, 'milk');
    // Both a task and a note match; each group header is shown.
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.text('Milk alternatives'), findsOneWidget);
    expect(find.textContaining('Tasks'), findsWidgets);
    expect(find.textContaining('Notes'), findsWidgets);
  });

  testWidgets('given_type_filter_when_notes_selected_then_scopes_results', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await type(tester, 'milk');
    await tester.tap(find.widgetWithText(FilterChip, 'Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Milk alternatives'), findsOneWidget);
    expect(find.text('Buy milk'), findsNothing);
  });

  testWidgets('given_unmatched_query_when_typed_then_shows_no_results', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await type(tester, 'zzz');
    expect(find.textContaining('No matches'), findsOneWidget);
  });

  testWidgets('given_result_when_rendered_then_exposes_open_accessible_name', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await harness.pumpApp(tester);
    await type(tester, 'milk');
    expect(find.bySemanticsLabel('Open Buy milk'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('given_query_when_saved_then_chip_appears_and_persists', (
    WidgetTester tester,
  ) async {
    await harness.pumpApp(tester);
    await type(tester, 'milk');

    await tester.tap(find.byTooltip('Save this search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Milk run');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The saved chip is shown.
    expect(find.widgetWithText(InputChip, 'Milk run'), findsOneWidget);
    // And it is durably persisted.
    final List<SavedSearchFilter> stored = await harness.savedFilters.load(
      harness.profileId,
    );
    expect(stored.single.name, 'Milk run');
    expect(stored.single.query, 'milk');
  });

  testWidgets('given_saved_filter_when_applied_then_query_recalled', (
    WidgetTester tester,
  ) async {
    await harness.savedFilters.save(harness.profileId, <SavedSearchFilter>[
      const SavedSearchFilter(
        id: 'f1',
        name: 'Milk run',
        query: 'milk',
        types: <String>{'note'},
      ),
    ]);
    await harness.pumpApp(tester);

    await tester.tap(find.widgetWithText(InputChip, 'Milk run'));
    await tester.pumpAndSettle();

    // The recalled query scopes to notes only.
    expect(find.text('Milk alternatives'), findsOneWidget);
    expect(find.text('Buy milk'), findsNothing);
  });
}
