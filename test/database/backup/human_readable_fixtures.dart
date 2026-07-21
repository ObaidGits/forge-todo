import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';

/// Seeds a small portable-domain store for human-readable export/import tests:
/// a profile, life areas, and tasks (a parent → child reference through
/// `life_area_id`), plus optional tombstoned rows. Synthetic data only.
Future<void> seedPortableStore(
  MigrationConnection c, {
  int areas = 2,
  int tasks = 3,
  bool withDeletedTask = false,
}) async {
  await c.execute(
    'CREATE TABLE profiles ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'display_name TEXT NOT NULL)',
  );
  await c.execute(
    'INSERT INTO profiles (id, display_name) VALUES (?, ?)',
    <Object?>['profile-1', 'Owner'],
  );
  await c.execute(
    'CREATE TABLE life_areas ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'profile_id TEXT NOT NULL, '
    'name TEXT NOT NULL, '
    'rank TEXT NOT NULL, '
    'deleted_at_utc INTEGER)',
  );
  await c.execute(
    'CREATE TABLE tasks ('
    'id TEXT NOT NULL PRIMARY KEY, '
    'profile_id TEXT NOT NULL, '
    'life_area_id TEXT NOT NULL REFERENCES life_areas(id), '
    'title TEXT NOT NULL, '
    'note_id TEXT, '
    'deleted_at_utc INTEGER)',
  );
  for (int i = 0; i < areas; i += 1) {
    await c.execute(
      'INSERT INTO life_areas (id, profile_id, name, rank, deleted_at_utc) '
      'VALUES (?, ?, ?, ?, NULL)',
      <Object?>['area-$i', 'profile-1', 'Area $i', 'a$i'],
    );
  }
  for (int i = 0; i < tasks; i += 1) {
    await c.execute(
      'INSERT INTO tasks (id, profile_id, life_area_id, title, note_id, '
      'deleted_at_utc) VALUES (?, ?, ?, ?, NULL, NULL)',
      <Object?>['task-$i', 'profile-1', 'area-0', 'Task $i'],
    );
  }
  if (withDeletedTask) {
    await c.execute(
      'INSERT INTO tasks (id, profile_id, life_area_id, title, note_id, '
      'deleted_at_utc) VALUES (?, ?, ?, ?, NULL, ?)',
      <Object?>['task-deleted', 'profile-1', 'area-0', 'Gone', 999],
    );
  }
}
