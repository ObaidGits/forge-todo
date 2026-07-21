import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'search_test_support.dart';

/// Offline search returns useful local results and targets first results
/// ≤ 150 ms p95 at a representative local scale.
///
/// **Validates: Requirements R-SEARCH-003**
void main() {
  late SearchHarness h;

  setUp(() async {
    h = await SearchHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  // A representative local task corpus. Titles are drawn from a small vocabulary
  // so queries return non-trivial result sets.
  const List<String> vocab = <String>[
    'report',
    'invoice',
    'design',
    'review',
    'release',
    'meeting',
    'budget',
    'roadmap',
    'research',
    'proposal',
  ];
  const int docCount = 3000;
  const int sampleQueries = 120;

  Future<void> seedCorpus() async {
    final String profile = h.profileId.value;
    await h.db.transaction(() async {
      for (int i = 0; i < docCount; i++) {
        final String word = vocab[i % vocab.length];
        final String word2 = vocab[(i * 7 + 3) % vocab.length];
        final String title = 'Task $i $word $word2 item';
        final int rowid = i + 1;
        await h.db.customStatement(
          'INSERT INTO fts_rowids '
          '(profile_id, entity_type, entity_id, fts_rowid, created_at_utc) '
          'VALUES (?, ?, ?, ?, 0)',
          <Object?>[profile, 'task', 't$i', rowid],
        );
        await h.db.customStatement(
          'INSERT INTO search_documents '
          '(doc_rowid, profile_id, entity_type, entity_id, title, body, '
          'weight_version, title_weight, body_weight, source_revision, '
          'deleted, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, 1, 10.0, 1.0, 1, 0, 0)',
          <Object?>[rowid, profile, 'task', 't$i', title, ''],
        );
        await h.db.customStatement(
          'INSERT INTO search_fts(rowid, title, body) VALUES (?, ?, ?)',
          <Object?>[rowid, title, ''],
        );
      }
    });
  }

  test('[TEST-SEARCH-LATENCY-001][MVP][TASK-4.6][R-SEARCH-003] first results '
      'return within the p95 budget at reference-scale local data', () async {
    await seedCorpus();
    expect(
      await h.scalarInt('SELECT COUNT(*) AS n FROM search_documents'),
      docCount,
    );

    // Warm up: prepare the statement and page cache.
    for (int i = 0; i < 10; i++) {
      await h.reads.search(h.profileId, vocab[i % vocab.length]);
    }

    final List<double> millis = <double>[];
    for (int i = 0; i < sampleQueries; i++) {
      final String query = vocab[i % vocab.length];
      final Stopwatch sw = Stopwatch()..start();
      final SearchResults results = await h.reads.search(
        h.profileId,
        query,
        limit: 50,
      );
      sw.stop();
      expect(results.totalHits, greaterThan(0));
      millis.add(sw.elapsedMicroseconds / 1000.0);
    }

    millis.sort();
    final double p95 =
        millis[(millis.length * 0.95).floor().clamp(0, millis.length - 1)];
    // Generous headroom over the 150 ms budget; FTS on local data is far
    // faster, and this asserts we have not regressed into a full scan.
    expect(
      p95,
      lessThan(150.0),
      reason: 'search p95 = ${p95.toStringAsFixed(2)} ms exceeds 150 ms',
    );
  });

  test(
    '[TEST-SEARCH-OFFLINE-001][MVP][TASK-4.6][R-SEARCH-003] the query plan uses '
    'the FTS index rather than scanning search_documents',
    () async {
      await seedCorpus();
      final List<QueryRow> plan = await h.db
          .customSelect(
            'EXPLAIN QUERY PLAN '
            'SELECT d.entity_id FROM search_fts '
            'JOIN search_documents d ON d.doc_rowid = search_fts.rowid '
            "WHERE search_fts MATCH 'report' AND d.profile_id = 'x' "
            'AND d.deleted = 0',
          )
          .get();
      final String detail = plan
          .map((QueryRow r) => r.data['detail'] as String)
          .join(' | ');
      expect(detail.toLowerCase(), contains('search_fts'));
      // The content table is reached by rowid lookup, not a scan.
      expect(detail.toLowerCase(), isNot(contains('scan search_documents')));
    },
  );
}
