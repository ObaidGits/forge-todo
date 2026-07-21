import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-VERIFY-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

Future<void> _createPair(MigrationConnection c) async {
  await c.execute(
    'CREATE TABLE items (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL)',
  );
  await c.execute(
    'CREATE TABLE item_events ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'item_id TEXT NOT NULL REFERENCES items(id))',
  );
}

void main() {
  group('given the post-backfill verifier', () {
    late Sqlite3MigrationConnection source;
    late Sqlite3MigrationConnection shadow;

    setUp(() async {
      source = Sqlite3MigrationConnection(sqlite3.openInMemory());
      shadow = Sqlite3MigrationConnection(sqlite3.openInMemory());
      await _createPair(source);
      await _createPair(shadow);
      await source.execute("INSERT INTO items VALUES ('a', 'A')");
      await source.execute("INSERT INTO items VALUES ('b', 'B')");
    });

    tearDown(() async {
      await source.dispose();
      await shadow.dispose();
    });

    testWithEvidence(
      _evidence('001'),
      'equal row counts, integrity, and FKs pass verification',
      () async {
        await shadow.execute("INSERT INTO items VALUES ('a', 'A')");
        await shadow.execute("INSERT INTO items VALUES ('b', 'B')");
        const MigrationVerifier verifier = MigrationVerifier();
        final VerificationReport report = await verifier.verify(
          source: source,
          shadow: shadow,
          preservedTables: <String>['items'],
        );
        expect(report.passed, isTrue, reason: report.firstFailure);
      },
    );

    testWithEvidence(
      _evidence('002'),
      'a preserved-table row-count mismatch fails verification',
      () async {
        await shadow.execute("INSERT INTO items VALUES ('a', 'A')");
        // Missing 'b': counts diverge.
        const MigrationVerifier verifier = MigrationVerifier();
        final VerificationReport report = await verifier.verify(
          source: source,
          shadow: shadow,
          preservedTables: <String>['items'],
        );
        expect(report.passed, isFalse);
        expect(report.firstFailure, contains('row_count'));
      },
    );

    testWithEvidence(
      _evidence('003'),
      'a dangling foreign key in the shadow fails verification',
      () async {
        // Disable FK enforcement so the bad row inserts, then let the verifier
        // detect it via PRAGMA foreign_key_check.
        await shadow.execute('PRAGMA foreign_keys = OFF');
        await shadow.execute("INSERT INTO items VALUES ('a', 'A')");
        await shadow.execute("INSERT INTO items VALUES ('b', 'B')");
        await shadow.execute(
          "INSERT INTO item_events (id, item_id) VALUES ('e1', 'ghost')",
        );
        const MigrationVerifier verifier = MigrationVerifier();
        final VerificationReport report = await verifier.verify(
          source: source,
          shadow: shadow,
          preservedTables: <String>['items'],
        );
        expect(report.passed, isFalse);
        expect(report.firstFailure, contains('foreign_key_check'));
      },
    );
  });

  group('given an FTS5 external-content index in a shadow generation', () {
    // Migration/restore integrity is a non-quarantinable release suite
    // (testing.md §14). FTS5 is a hard production build contract — the unified
    // search schema (search_schema_test.dart) requires it unconditionally — so
    // these tests run unconditionally rather than silently skipping on a build
    // that lacks FTS5. Absence of FTS5 is a release-blocking build defect, made
    // legible here instead of bypassing the FTS integrity verifier.
    test(
      _evidence('BUILD-CONTRACT').testName(
        'the bundled SQLite build provides FTS5 (release build contract)',
      ),
      () {
        expect(
          sqliteHasFts5(),
          isTrue,
          reason:
              'Release build contract: the bundled SQLite must provide FTS5. '
              'Migration/restore integrity suites are non-quarantinable and '
              'cannot be bypassed on the release commit.',
        );
      },
    );

    test(
      _evidence(
        '004',
      ).testName('a consistent index passes FTS integrity verification'),
      () async {
        final Sqlite3MigrationConnection conn = Sqlite3MigrationConnection(
          sqlite3.openInMemory(),
        );
        try {
          await conn.execute(
            'CREATE TABLE search_documents ('
            'rowid INTEGER PRIMARY KEY, title TEXT, body TEXT)',
          );
          await conn.execute(
            'CREATE VIRTUAL TABLE search_fts USING fts5('
            "title, body, content='search_documents', content_rowid='rowid')",
          );
          await conn.execute(
            "INSERT INTO search_documents (rowid, title, body) "
            "VALUES (1, 'alpha', 'first body')",
          );
          await conn.execute(
            "INSERT INTO search_fts (rowid, title, body) "
            "VALUES (1, 'alpha', 'first body')",
          );
          const FtsIntegrityVerifier verifier = FtsIntegrityVerifier();
          final FtsIntegrityReport report = await verifier.verify(conn);
          expect(report.ftsTables, contains('search_fts'));
          expect(report.passed, isTrue, reason: report.failures.join('; '));
        } finally {
          await conn.dispose();
        }
      },
    );

    test(
      _evidence('005').testName(
        'a corrupted external-content index is caught by verification',
      ),
      () async {
        final Sqlite3MigrationConnection conn = Sqlite3MigrationConnection(
          sqlite3.openInMemory(),
        );
        try {
          await conn.execute(
            'CREATE TABLE search_documents ('
            'rowid INTEGER PRIMARY KEY, title TEXT, body TEXT)',
          );
          await conn.execute(
            'CREATE VIRTUAL TABLE search_fts USING fts5('
            "title, body, content='search_documents', content_rowid='rowid')",
          );
          // Content row exists but the index was never populated: the built-in
          // integrity-check must flag the divergence.
          await conn.execute(
            "INSERT INTO search_documents (rowid, title, body) "
            "VALUES (1, 'alpha', 'first body')",
          );
          await conn.execute(
            "INSERT INTO search_fts (rowid, title, body) "
            "VALUES (1, 'wrong', 'mismatch')",
          );
          const FtsIntegrityVerifier verifier = FtsIntegrityVerifier();
          final FtsIntegrityReport report = await verifier.verify(conn);
          expect(report.passed, isFalse);
        } finally {
          await conn.dispose();
        }
      },
    );
  });
}
