import 'package:drift/native.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';

/// Opens a fresh in-memory core-schema database.
///
/// This exercises the real Drift schema DDL, constraints, and indexes against a
/// native SQLite build. `PRAGMA foreign_keys = ON` is applied by the schema's
/// `beforeOpen`, so referential and CHECK constraints are enforced exactly as
/// they will be behind the encrypted-store boundary.
ForgeSchemaDatabase openSchemaDatabase() =>
    ForgeSchemaDatabase(NativeDatabase.memory());

/// Inserts a minimal profile row and returns its id.
Future<String> insertProfile(
  ForgeSchemaDatabase db, {
  String id = 'profile-1',
  bool isActive = true,
}) async {
  await db.customStatement(
    'INSERT INTO profiles '
    '(id, display_name, locale, timezone_id, week_start, hour_format, '
    'is_active, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[id, 'Owner', 'en', 'UTC', 1, 'h24', isActive ? 1 : 0, 0, 0],
  );
  return id;
}

/// Inserts a tag owned by [profileId] and returns its id.
Future<String> insertTag(
  ForgeSchemaDatabase db,
  String profileId, {
  String id = 'tag-1',
  String normalizedName = 'work',
}) async {
  await db.customStatement(
    'INSERT INTO tags '
    '(id, profile_id, normalized_name, display_name, created_at_utc, '
    'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
    <Object?>[id, profileId, normalizedName, 'Work', 0, 0],
  );
  return id;
}
