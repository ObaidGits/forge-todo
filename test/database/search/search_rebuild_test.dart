import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/infrastructure/search_index_maintenance.dart';

import 'search_test_support.dart';

/// Migration/rebuild tooling regenerates the index entirely from source rows,
/// verifies FTS integrity, and repairs the index without touching source rows.
///
/// **Validates: Requirements R-SEARCH-001, R-SEARCH-003, R-NOTE-004**
void main() {
  late SearchHarness h;

  setUp(() async {
    h = await SearchHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given source rows when rebuilding from sources', () {
    test('then every active task document is regenerated', () async {
      final String a = await h.createTask('rebuild alpha');
      final String b = await h.createTask('rebuild beta');
      await h.createTask('rebuild gamma');

      // Corrupt the projection state: wipe documents and the index entirely.
      await h.db.customStatement('DELETE FROM search_documents');
      await h.db.customStatement('DELETE FROM fts_rowids');
      await h.db.customStatement(
        "INSERT INTO search_fts(search_fts) VALUES('delete-all')",
      );
      expect((await h.search.search(h.profileId, 'rebuild')).totalHits, 0);

      final int regenerated = await h.maintenance.rebuildFromSources(
        h.profileId.value,
      );
      expect(regenerated, 3);

      final SearchResults results = await h.search.search(
        h.profileId,
        'rebuild',
      );
      expect(results.totalHits, 3);
      final Set<String> ids = results.groups
          .expand((SearchResultGroup g) => g.hits)
          .map((SearchHit hit) => hit.entityId)
          .toSet();
      expect(ids, containsAll(<String>[a, b]));
    });

    test('then a deleted task is not regenerated', () async {
      final String keep = await h.createTask('keep me indexed');
      final String drop = await h.createTask('drop me now');
      await h.softDeleteRow(
        drop,
        atUtc: h.clock.utcNow().microsecondsSinceEpoch,
      );

      final int regenerated = await h.maintenance.rebuildFromSources(
        h.profileId.value,
      );
      expect(regenerated, 1);
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM search_documents WHERE entity_id = ?',
          <Object?>[keep],
        ),
        1,
      );
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM search_documents WHERE entity_id = ?',
          <Object?>[drop],
        ),
        0,
      );
    });
  });

  group('given the FTS index when checking integrity', () {
    test('then a healthy index passes the integrity check', () async {
      await h.createTask('integrity healthy');
      final SearchIntegrityReport report = await h.maintenance.integrityCheck();
      expect(report.ok, isTrue, reason: report.error);
    });

    test(
      'then rebuildIndex restores queries after a content refresh',
      () async {
        final String id = await h.createTask('index rebuild target');
        // Rebuild the FTS index from the content table; queries still work.
        await h.maintenance.rebuildIndex();
        final SearchIntegrityReport report = await h.maintenance
            .integrityCheck();
        expect(report.ok, isTrue, reason: report.error);
        final SearchResults results = await h.search.search(
          h.profileId,
          'rebuild',
        );
        expect(
          results.groups
              .expand((SearchResultGroup g) => g.hits)
              .map((SearchHit hit) => hit.entityId),
          contains(id),
        );
      },
    );
  });
}
