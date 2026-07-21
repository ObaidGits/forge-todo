import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'search_test_support.dart';

/// The task contributor maintains its search rows in the SAME transaction as
/// the domain write; edits keep a stable row id; tombstones hide documents; and
/// the read model groups, filters and highlights safely.
///
/// **Validates: Requirements R-SEARCH-001, R-SEARCH-002, R-SEARCH-003,
/// R-NOTE-004**
void main() {
  late SearchHarness h;

  setUp(() async {
    h = await SearchHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given a created task when the command commits', () {
    test('then a search document and FTS row are written atomically', () async {
      final String id = await h.createTask('Buy oat milk');

      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM search_documents WHERE entity_id = ?',
          <Object?>[id],
        ),
        1,
      );
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM fts_rowids WHERE entity_id = ?',
          <Object?>[id],
        ),
        1,
      );
      final SearchResults results = await h.search.search(h.profileId, 'milk');
      expect(results.totalHits, 1);
      expect(results.groups.single.entityType, 'task');
      expect(results.groups.single.hits.single.entityId, id);
    });

    test(
      'then the search dirty marker is cleared in the same transaction',
      () async {
        await h.createTask('Write report');
        // The in-transaction coordinator projects and clears the search marker;
        // no pending search marker remains.
        expect(
          await h.scalarInt(
            "SELECT COUNT(*) FROM projection_dirty WHERE projection = 'search'",
          ),
          0,
        );
        // The Today marker (no in-transaction projector) is still pending.
        expect(
          await h.scalarInt(
            "SELECT COUNT(*) FROM projection_dirty WHERE projection = 'today'",
          ),
          1,
        );
      },
    );
  });

  group('given an edited task when its title changes', () {
    test('then search reflects the new title and drops the old', () async {
      final String id = await h.createTask('Draft proposal');
      await h.updateTitle(id, 'Final proposal');

      final SearchResults stale = await h.search.search(h.profileId, 'Draft');
      expect(stale.totalHits, 0);
      final SearchResults fresh = await h.search.search(h.profileId, 'Final');
      expect(fresh.totalHits, 1);
      expect(fresh.groups.single.hits.single.entityId, id);
    });

    test('then the stable FTS row id is preserved across edits', () async {
      final String id = await h.createTask('Alpha');
      final Map<String, Object?>? before = await h.firstRow(
        'SELECT fts_rowid FROM fts_rowids WHERE entity_id = ?',
        <Object?>[id],
      );
      await h.updateTitle(id, 'Beta');
      await h.updateTitle(id, 'Gamma');
      final Map<String, Object?>? after = await h.firstRow(
        'SELECT fts_rowid FROM fts_rowids WHERE entity_id = ?',
        <Object?>[id],
      );
      expect(after!['fts_rowid'], before!['fts_rowid']);
      // Exactly one mapping and one document survive repeated edits.
      expect(
        await h.scalarInt(
          'SELECT COUNT(*) FROM search_documents WHERE entity_id = ?',
          <Object?>[id],
        ),
        1,
      );
    });
  });

  group('given a completed task when it is still a task', () {
    test('then a completed task remains searchable', () async {
      final String id = await h.createTask('Ship the release');
      await h.completeTask(id);
      final SearchResults results = await h.search.search(
        h.profileId,
        'release',
      );
      expect(results.totalHits, 1);
      expect(results.groups.single.hits.single.entityId, id);
    });
  });

  group('given multiple types when grouping results', () {
    test('then hits are grouped by entity type', () async {
      await h.createTask('Report quarterly numbers');
      await h.createTask('Report weekly numbers');

      final SearchResults results = await h.search.search(
        h.profileId,
        'Report',
      );
      expect(results.totalHits, 2);
      expect(results.groups, hasLength(1));
      expect(results.groups.single.entityType, 'task');
    });

    test('then a type filter restricts results to the selected type', () async {
      await h.createTask('Filterable task');

      final SearchResults none = await h.search.search(
        h.profileId,
        'Filterable',
        types: <String>{'note'},
      );
      expect(none.totalHits, 0);
      final SearchResults some = await h.search.search(
        h.profileId,
        'Filterable',
        types: <String>{'task'},
      );
      expect(some.totalHits, 1);
    });
  });

  group('given untrusted query text when searching', () {
    test('then FTS operators in the query cannot break the search', () async {
      await h.createTask('quarterly report');
      // Each of these would be a syntax error or operator injection if passed
      // to FTS raw; the sanitizer must treat them as literal tokens so the
      // query completes safely (returning zero or more hits, never throwing).
      for (final String malicious in <String>[
        'report"',
        'report OR title:x',
        'report*(',
        'NEAR(report',
        '^report AND',
        '"))--',
        'report AND (title : "x',
      ]) {
        final SearchResults results = await h.search.search(
          h.profileId,
          malicious,
        );
        expect(
          results.totalHits,
          greaterThanOrEqualTo(0),
          reason: 'query "$malicious" must not throw or inject',
        );
      }
    });

    test(
      'then a single literal token still matches by AND semantics',
      () async {
        final String id = await h.createTask('quarterly report');
        // "report review" -> AND of both tokens; the doc has only "report".
        expect(
          (await h.search.search(h.profileId, 'report review')).totalHits,
          0,
        );
        // A single present token matches.
        final SearchResults hit = await h.search.search(h.profileId, 'report');
        expect(
          hit.groups
              .expand((SearchResultGroup g) => g.hits)
              .map((SearchHit x) => x.entityId),
          contains(id),
        );
      },
    );

    test('then highlighting wraps matches with safe markers', () async {
      await h.createTask('highlight me please');
      final SearchResults results = await h.search.search(
        h.profileId,
        'highlight',
      );
      final SearchHit hit = results.groups.single.hits.single;
      expect(hit.titleHighlighted, contains(SearchMarkers.openTest));
      expect(hit.titleHighlighted, contains(SearchMarkers.closeTest));
      // The plain title is preserved for display fallback.
      expect(hit.title, 'highlight me please');
    });
  });

  group('given offline operation when querying', () {
    test('then empty or operator-only queries return no results', () async {
      await h.createTask('anything');
      expect((await h.search.search(h.profileId, '')).isEmpty, isTrue);
      expect((await h.search.search(h.profileId, '   ')).isEmpty, isTrue);
      expect((await h.search.search(h.profileId, '"*()')).isEmpty, isTrue);
    });
  });
}

/// Mirrors the private highlight markers for assertions.
abstract final class SearchMarkers {
  static const String openTest = '\u0002';
  static const String closeTest = '\u0003';
}
