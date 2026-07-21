import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/search/application/saved_filters_store.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/infrastructure/settings_saved_filters_store.dart';
import 'package:forge/features/search/presentation/search_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../../database/schema/schema_test_database.dart';

/// A canned [SearchService] used to exercise the search UI's grouping,
/// filtering, and highlighting without depending on the FTS index internals
/// (those are covered by the search infrastructure tests). Returns hits whose
/// title contains the query, scoped by the requested types.
final class FakeSearchService implements SearchService {
  static const List<SearchHit> _catalog = <SearchHit>[
    SearchHit(
      entityType: 'task',
      entityId: '018f0000-0000-7000-8000-000000000001',
      title: 'Buy milk',
      titleHighlighted: 'Buy \u0002milk\u0003',
      bodySnippet: 'from the store',
      score: 1,
    ),
    SearchHit(
      entityType: 'note',
      entityId: '018f0000-0000-7000-8000-000000000002',
      title: 'Milk alternatives',
      titleHighlighted: '\u0002Milk\u0003 alternatives',
      bodySnippet: 'oat, soy',
      score: 2,
    ),
  ];

  @override
  Future<SearchResults> search(
    ProfileId profileId,
    String query, {
    Set<String>? types,
    bool prefix = true,
    int limit = 50,
  }) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return SearchResults.empty;
    }
    final List<SearchHit> hits = _catalog
        .where(
          (SearchHit h) =>
              h.title.toLowerCase().contains(q) &&
              (types == null || types.contains(h.entityType)),
        )
        .toList();
    if (hits.isEmpty) {
      return SearchResults.empty;
    }
    final Map<String, List<SearchHit>> byType = <String, List<SearchHit>>{};
    final List<String> order = <String>[];
    for (final SearchHit hit in hits) {
      byType
          .putIfAbsent(hit.entityType, () {
            order.add(hit.entityType);
            return <SearchHit>[];
          })
          .add(hit);
    }
    return SearchResults(
      groups: order
          .map((String t) => SearchResultGroup(entityType: t, hits: byType[t]!))
          .toList(),
      totalHits: hits.length,
    );
  }
}

/// Composes the search presentation stack: a canned search service plus a real
/// settings-backed saved-filters store over an in-memory database.
final class SearchWidgetHarness {
  SearchWidgetHarness._({
    required this.db,
    required this.profileId,
    required this.savedFilters,
  });

  static Future<SearchWidgetHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String id = await insertProfile(db);
    return SearchWidgetHarness._(
      db: db,
      profileId: ProfileId(id),
      savedFilters: SettingsSavedFiltersStore(db, const _FixedClock()),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final SavedFiltersStore savedFilters;
  final FakeSearchService search = FakeSearchService();

  Future<void> close() => db.close();

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1100, 1800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createForgeRouter(initialLocation: '/search');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchProfileProvider.overrideWithValue(profileId),
          searchServiceProvider.overrideWithValue(search),
          savedFiltersStoreProvider.overrideWithValue(savedFilters),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ForgeTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime utcNow() => DateTime.utc(2024, 6, 15, 9);
  @override
  String timezoneId() => 'UTC';
}
