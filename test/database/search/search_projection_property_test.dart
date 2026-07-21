import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'search_test_support.dart';

/// Randomized property test: across arbitrary create/edit/rebuild sequences the
/// unified index stays internally consistent — one indexed row per live
/// document, stable row ids per entity, FTS integrity intact, and every current
/// title findable.
///
/// **Validates: Requirements R-SEARCH-001, R-SEARCH-003, R-NOTE-004**
void main() {
  // Deterministic seeds so a failure is reproducible.
  for (final int seed in <int>[1, 7, 42, 1337]) {
    test(
      '[TEST-SEARCH-PROP-001][MVP][TASK-4.6][R-SEARCH-001,R-SEARCH-003,'
      'R-NOTE-004] index stays consistent under random operations (seed=$seed)',
      () async {
        final SearchHarness h = await SearchHarness.open();
        addTearDown(h.close);
        final Random random = Random(seed);

        const List<String> words = <String>[
          'apple',
          'bridge',
          'crystal',
          'delta',
          'ember',
          'falcon',
        ];
        // entity id -> current word title, and its allocated fts row id.
        final Map<String, String> titles = <String, String>{};
        final Map<String, int> rowids = <String, int>{};

        for (int step = 0; step < 40; step++) {
          final int roll = random.nextInt(10);
          final String word = words[random.nextInt(words.length)];
          if (titles.isEmpty || roll < 5) {
            // Create.
            final String id = await h.createTask('$word ${titles.length}');
            titles[id] = word;
          } else if (roll < 8) {
            // Edit an existing task's title word.
            final String id = titles.keys.elementAt(
              random.nextInt(titles.length),
            );
            await h.updateTitle(id, '$word ${id.hashCode & 0xff}');
            titles[id] = word;
          } else {
            // Full source rebuild; must be a no-op for consistency.
            await h.maintenance.rebuildFromSources(h.profileId.value);
          }

          // Track stable row ids: once assigned, an entity's row id never
          // changes.
          for (final String id in titles.keys) {
            final Map<String, Object?>? row = await h.firstRow(
              'SELECT fts_rowid FROM fts_rowids WHERE entity_id = ?',
              <Object?>[id],
            );
            expect(row, isNotNull, reason: 'entity $id must have a row id');
            final int rowid = row!['fts_rowid'] as int;
            final int? previous = rowids[id];
            if (previous != null) {
              expect(rowid, previous, reason: 'row id for $id must be stable');
            }
            rowids[id] = rowid;
          }

          // Invariant: exactly one non-deleted document per live entity, and
          // the FTS index has one row per non-deleted document.
          final int liveDocs = await h.scalarInt(
            'SELECT COUNT(*) FROM search_documents WHERE deleted = 0',
          );
          expect(liveDocs, titles.length);
          final int ftsRows = await h.scalarInt(
            'SELECT COUNT(*) FROM search_fts',
          );
          expect(ftsRows, titles.length);

          // Invariant: the FTS index is consistent with its content table.
          final report = await h.maintenance.integrityCheck();
          expect(report.ok, isTrue, reason: report.error);
        }

        // Every current title is findable by its word (grouped under 'task').
        for (final MapEntry<String, String> entry in titles.entries) {
          final SearchResults results = await h.search.search(
            h.profileId,
            entry.value,
          );
          final Iterable<String> ids = results.groups
              .expand((SearchResultGroup g) => g.hits)
              .map((SearchHit hit) => hit.entityId);
          expect(
            ids,
            contains(entry.key),
            reason: 'task ${entry.key} titled "${entry.value}" must be found',
          );
        }
      },
    );
  }
}
