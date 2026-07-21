import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/application/saved_filters_store.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';
import 'package:forge/features/search/presentation/search_providers.dart';
import 'package:forge/features/tasks/presentation/saved_filter_task_list_screen.dart';
import 'package:forge/features/tasks/presentation/task_list_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the recalled saved-filter task list (`/tasks/filter/
/// :filterId`) (R-SEARCH-002, R-TASK-008).
void main() {
  const Widget child = SavedFilterTaskListScreen(filterId: 'f1');

  MaterialApp app() => const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  Widget host(List<SavedSearchFilter> filters) => ProviderScope(
    overrides: [
      searchProfileProvider.overrideWithValue(ProfileId('p1')),
      savedFiltersStoreProvider.overrideWithValue(_FakeStore(filters)),
    ],
    child: app(),
  );

  testWidgets('given_matching_filter_when_opened_then_renders_task_list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(<SavedSearchFilter>[
        const SavedSearchFilter(
          id: 'f1',
          name: 'Urgent',
          query: 'invoice',
          types: <String>{},
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // The saved filter resolved: the task list surface renders (not the
    // not-found state).
    expect(find.byType(TaskListScreen), findsOneWidget);
    expect(find.text('Filter not found'), findsNothing);
  });

  testWidgets('given_unknown_filter_when_opened_then_shows_not_found', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(<SavedSearchFilter>[
        const SavedSearchFilter(
          id: 'other',
          name: 'Other',
          query: 'x',
          types: <String>{},
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Filter not found'), findsOneWidget);
    expect(find.byType(TaskListScreen), findsNothing);
  });
}

final class _FakeStore implements SavedFiltersStore {
  _FakeStore(this._filters);

  final List<SavedSearchFilter> _filters;

  @override
  Future<List<SavedSearchFilter>> load(ProfileId profileId) async => _filters;

  @override
  Future<void> save(
    ProfileId profileId,
    List<SavedSearchFilter> filters,
  ) async {}
}
