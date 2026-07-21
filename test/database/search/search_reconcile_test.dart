import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'search_test_support.dart';

/// Startup/resume reconciliation regenerates search documents from seeded
/// `search` markers, tombstones deleted entities, and skips markers with no
/// registered projector.
///
/// **Validates: Requirements R-SEARCH-001, R-NOTE-004**
void main() {
  late SearchHarness h;

  setUp(() async {
    h = await SearchHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> seedMarker(String key, {int sourceSeq = 1}) async {
    await h.db.customStatement(
      'INSERT INTO projection_dirty '
      '(profile_id, projection, projection_key, source_commit_seq, attempts, '
      'updated_at_utc) VALUES (?, ?, ?, ?, 0, 0) '
      'ON CONFLICT(profile_id, projection, projection_key) DO UPDATE SET '
      'source_commit_seq = excluded.source_commit_seq',
      <Object?>[h.profileId.value, 'search', key, sourceSeq],
    );
  }

  group('given a seeded search marker when reconciling', () {
    test('then the document is regenerated and the marker cleared', () async {
      // Create a task, then clear the index to simulate a fresh generation that
      // still has a durable dirty marker to replay.
      final String id = await h.createTask('Reconcile me');
      await h.maintenance.rebuildFromSources(h.profileId.value);
      // Remove the doc so reconcile has real work, and seed its marker.
      await h.db.customStatement('DELETE FROM search_documents');
      await h.db.customStatement(
        "INSERT INTO search_fts(search_fts) VALUES('delete-all')",
      );
      await seedMarker('task:$id');

      final report = await h.reconciler.reconcile(h.profileId.value);
      expect(report.reconciled, 1);
      expect(report.failed, 0);
      expect(report.skipped, 0);

      final SearchResults results = await h.search.search(
        h.profileId,
        'Reconcile',
      );
      expect(results.totalHits, 1);
      expect(
        await h.scalarInt(
          "SELECT COUNT(*) FROM projection_dirty WHERE projection = 'search'",
        ),
        0,
      );
    });

    test('then a soft-deleted entity is tombstoned on reconcile', () async {
      final String id = await h.createTask('Delete me');
      expect((await h.search.search(h.profileId, 'Delete')).totalHits, 1);

      await h.softDeleteRow(id, atUtc: h.clock.utcNow().microsecondsSinceEpoch);
      await seedMarker('task:$id', sourceSeq: 2);

      final report = await h.reconciler.reconcile(h.profileId.value);
      expect(report.reconciled, 1);

      expect((await h.search.search(h.profileId, 'Delete')).totalHits, 0);
      // The document row is hidden but its stable row-id mapping is preserved.
      expect(
        await h.scalarInt(
          'SELECT deleted FROM search_documents WHERE entity_id = ?',
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
    });

    test('then an unknown entity type is skipped, not failed', () async {
      await seedMarker('workout:w1');
      final report = await h.reconciler.reconcile(h.profileId.value);
      expect(report.skipped, 1);
      expect(report.reconciled, 0);
      expect(report.failed, 0);
      // The marker is left in place for a future wave's projector.
      expect(
        await h.scalarInt(
          "SELECT COUNT(*) FROM projection_dirty WHERE projection = 'search'",
        ),
        1,
      );
    });

    test('then a malformed marker key is skipped', () async {
      await seedMarker('no-separator-key');
      final report = await h.reconciler.reconcile(h.profileId.value);
      expect(report.skipped, 1);
    });
  });
}
