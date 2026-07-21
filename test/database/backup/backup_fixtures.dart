import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';

/// Seeds a small but structurally representative encrypted-store stand-in for
/// backup tests: a singleton `schema_metadata`, a `commit_log` carrying a
/// monotonic `commit_seq`, a parent/child domain pair with a real foreign key,
/// and (optionally) an FTS5 index so restore verification exercises FTS
/// integrity. Data is synthetic only.
Future<void> seedBackupStore(
  MigrationConnection c, {
  required int commitSeq,
  int schemaVersion = 1,
  String generationId = 'gen-source',
  int items = 5,
  bool withFts = true,
}) async {
  await c.execute(
    'CREATE TABLE schema_metadata ('
    'id INTEGER PRIMARY KEY DEFAULT 1, '
    'schema_version INTEGER NOT NULL, '
    'cipher_version TEXT NOT NULL, '
    'build_id TEXT NOT NULL, '
    'generation_id TEXT NOT NULL, '
    'migration_state TEXT NOT NULL, '
    'updated_at_utc INTEGER NOT NULL, '
    'CHECK (id = 1))',
  );
  await c.execute(
    'INSERT INTO schema_metadata '
    '(id, schema_version, cipher_version, build_id, generation_id, '
    'migration_state, updated_at_utc) VALUES (1, ?, ?, ?, ?, ?, 0)',
    <Object?>[schemaVersion, 'v1', 'build-1', generationId, 'active'],
  );
  await c.execute(
    'CREATE TABLE commit_log ('
    'profile_id TEXT NOT NULL, '
    'commit_seq INTEGER NOT NULL, '
    'command_id TEXT NOT NULL, '
    'committed_at INTEGER NOT NULL, '
    'PRIMARY KEY (profile_id, commit_seq))',
  );
  for (int seq = 1; seq <= commitSeq; seq += 1) {
    await c.execute(
      'INSERT INTO commit_log (profile_id, commit_seq, command_id, '
      'committed_at) VALUES (?, ?, ?, ?)',
      <Object?>['profile-1', seq, 'cmd-$seq', seq],
    );
  }
  await c.execute(
    'CREATE TABLE items ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'profile_id TEXT NOT NULL, '
    'title TEXT NOT NULL, '
    'created_at INTEGER NOT NULL)',
  );
  await c.execute(
    'CREATE TABLE item_events ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'item_id TEXT NOT NULL REFERENCES items(id), '
    'kind TEXT NOT NULL, '
    'at INTEGER NOT NULL)',
  );
  for (int i = 0; i < items; i += 1) {
    final String id = 'item-${i.toString().padLeft(4, '0')}';
    await c.execute(
      'INSERT INTO items (id, profile_id, title, created_at) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[id, 'profile-1', 'Title $i', i],
    );
    await c.execute(
      'INSERT INTO item_events (id, item_id, kind, at) VALUES (?, ?, ?, ?)',
      <Object?>['evt-${i.toString().padLeft(4, '0')}', id, 'created', i],
    );
  }
  if (withFts) {
    await c.execute('CREATE VIRTUAL TABLE search_fts USING fts5(body)');
    for (int i = 0; i < items; i += 1) {
      await c.execute('INSERT INTO search_fts (body) VALUES (?)', <Object?>[
        'searchable body $i',
      ]);
    }
  }
}
