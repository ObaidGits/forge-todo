import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';

/// Synthetic, immutable, all-version fixtures for migration tests.
///
/// The domain is deliberately tiny (`items` + `item_events`) but structurally
/// representative: a parent/child pair with a real foreign key, a singleton
/// `schema_metadata` row, an additive step (v1→v2) and an incompatible
/// restructuring step (v2→v3) that renames a column and adds a NOT NULL column,
/// forcing a shadow rebuild. Data is synthetic only (testing §5).

Future<void> createSchemaMetadata(MigrationConnection c) async {
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
}

Future<void> createV1Schema(MigrationConnection c) async {
  await createSchemaMetadata(c);
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
}

/// The complete v3 schema, built into a fresh shadow store.
Future<void> createV3Schema(MigrationConnection c) async {
  await createSchemaMetadata(c);
  await c.execute(
    'CREATE TABLE items ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'profile_id TEXT NOT NULL, '
    'name TEXT NOT NULL, '
    'status TEXT NOT NULL, '
    'priority INTEGER NOT NULL DEFAULT 0, '
    'created_at INTEGER NOT NULL)',
  );
  await c.execute(
    'CREATE TABLE item_events ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'item_id TEXT NOT NULL REFERENCES items(id), '
    'kind TEXT NOT NULL, '
    'at INTEGER NOT NULL)',
  );
}

/// Seeds [items] parents each with one child event. IDs are zero-padded so
/// lexicographic ordering (the backfill cursor) is deterministic.
Future<void> seedV1(
  MigrationConnection c, {
  required int items,
  String profileId = 'profile-1',
}) async {
  await c.execute(
    'INSERT INTO schema_metadata '
    '(id, schema_version, cipher_version, build_id, generation_id, '
    'migration_state, updated_at_utc) VALUES (1, 1, ?, ?, ?, ?, 0)',
    <Object?>['v1', 'build-1', 'gen-source', 'active'],
  );
  for (int i = 0; i < items; i += 1) {
    final String id = 'item-${i.toString().padLeft(6, '0')}';
    await c.execute(
      'INSERT INTO items (id, profile_id, title, created_at) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[id, profileId, 'Title $i', i],
    );
    await c.execute(
      'INSERT INTO item_events (id, item_id, kind, at) VALUES (?, ?, ?, ?)',
      <Object?>['evt-${i.toString().padLeft(6, '0')}', id, 'created', i],
    );
  }
}

/// v1→v2: additive column, applied transactionally in place.
MigrationPlan additiveV1toV2() => MigrationPlan(
  sourceVersion: 1,
  targetVersion: 2,
  requiresShadowGeneration: false,
  applyInPlace: (MigrationConnection c) async {
    await c.execute(
      'ALTER TABLE items ADD COLUMN priority INTEGER NOT NULL DEFAULT 0',
    );
  },
);

/// v2→v3: incompatible restructure requiring a shadow generation. Renames
/// `title`→`name` and adds a NOT NULL `status`.
MigrationPlan incompatibleV2toV3() => MigrationPlan(
  sourceVersion: 2,
  targetVersion: 3,
  requiresShadowGeneration: true,
  buildTargetSchema: createV3Schema,
  backfillTables: <BackfillTable>[
    BackfillTable(
      name: 'items',
      orderByColumn: 'id',
      transform: (Map<String, Object?> row) => <String, Object?>{
        'id': row['id'],
        'profile_id': row['profile_id'],
        'name': row['title'],
        'status': 'open',
        'priority': row['priority'] ?? 0,
        'created_at': row['created_at'],
      },
    ),
    const BackfillTable(name: 'item_events', orderByColumn: 'id'),
  ],
);

/// A single-step incompatible plan straight from v1 (used to test the shadow
/// path without an intervening additive step). Maps v1 rows (no `priority`)
/// directly to the v3 shape.
MigrationPlan incompatibleV1toV3Direct() => MigrationPlan(
  sourceVersion: 1,
  targetVersion: 2,
  requiresShadowGeneration: true,
  buildTargetSchema: createV3Schema,
  backfillTables: <BackfillTable>[
    BackfillTable(
      name: 'items',
      orderByColumn: 'id',
      transform: (Map<String, Object?> row) => <String, Object?>{
        'id': row['id'],
        'profile_id': row['profile_id'],
        'name': row['title'],
        'status': 'open',
        'priority': 0,
        'created_at': row['created_at'],
      },
    ),
    const BackfillTable(name: 'item_events', orderByColumn: 'id'),
  ],
);

/// Registry covering v1→v2 (additive) and v2→v3 (incompatible).
MigrationRegistry buildRegistry() =>
    MigrationRegistry(<MigrationPlan>[additiveV1toV2(), incompatibleV2toV3()]);
