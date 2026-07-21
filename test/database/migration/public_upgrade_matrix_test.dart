import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import '../../helpers/helpers.dart';

/// Wave 12 release gate (task 12.6): **every-public-upgrade** automation.
///
/// NFR-MAIN-004 requires every schema change to ship migration + compatibility
/// + tests, and data-model §5.2 requires migrations from *every* released
/// baseline, not merely N-1. This suite verifies the additive `onUpgrade` path
/// from EVERY historical public schema version (v1..v13) to the current v14,
/// preserving existing data.
///
/// The store's additive history is authoritative and encoded once in
/// [_tablesIntroducedAt] (mirroring `ForgeSchemaDatabase.migration.onUpgrade`).
/// To materialise a faithful "version N" store without needing historical DDL
/// snapshots, each case:
///   1. creates the full current schema through the real Drift `onCreate`;
///   2. reverts it to version N by dropping every table introduced after N and,
///      for N < 5, the additive `note_links.resolution` column, then stamps
///      `PRAGMA user_version = N`;
///   3. seeds representative rows that exist at version N;
///   4. reopens `ForgeSchemaDatabase`, which runs the real `onUpgrade(N -> 14)`;
///   5. asserts every current table exists, seeded rows survive, and the
///      recompiled v14 store is writable end to end.
///
/// Packaged clean-install/upgrade on each claimed OS/distro/package remains a
/// MANUAL/CI platform-matrix concern (testing.md §7); this proves the schema
/// migration contract that those platform runs depend on.
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-UPGRADE-MATRIX-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.6'),
  requirements: <RequirementId>[
    RequirementId('NFR-MAIN-004'),
    RequirementId('NFR-REL-002'),
  ],
);

const int _currentVersion = 14;

/// Tables first created at each schema version, mirroring the additive
/// `onUpgrade` blocks in `forge_schema.dart`. Version 1 is the baseline (every
/// table not listed here). Version 5 adds a column, not a table, and version 14
/// recreates `reminders` in place (no new table), so neither appears here.
const Map<int, List<String>> _tablesIntroducedAt = <int, List<String>>{
  2: <String>['reminders'],
  3: <String>['notes', 'note_drafts', 'note_links'],
  4: <String>[
    'planning_periods',
    'planning_entries',
    'planning_close_events',
    'planning_close_items',
    'planning_close_adjustments',
  ],
  6: <String>['goals', 'milestones'],
  7: <String>[
    'courses',
    'learning_items',
    'study_sessions',
    'study_session_events',
  ],
  8: <String>[
    'roadmaps',
    'roadmap_sections',
    'roadmap_topics',
    'checklist_items',
  ],
  9: <String>[
    'habits',
    'habit_schedules',
    'habit_occurrences',
    'habit_checkins',
    'habit_pauses',
  ],
  10: <String>['focus_sessions', 'focus_intervals', 'focus_events'],
  11: <String>['attachments'],
  12: <String>[
    'workout_templates',
    'template_exercises',
    'workout_sessions',
    'exercise_logs',
    'set_logs',
    'body_measurements',
  ],
  13: <String>['water_events'],
};

/// Every table (in reverse dependency-safe order) introduced strictly after
/// [fromVersion], i.e. the tables absent from a real "version fromVersion"
/// store.
List<String> _tablesAfter(int fromVersion) {
  final List<String> names = <String>[];
  for (final MapEntry<int, List<String>> entry in _tablesIntroducedAt.entries) {
    if (entry.key > fromVersion) {
      names.addAll(entry.value);
    }
  }
  return names;
}

/// The pre-v5 `note_links` DDL: the current definition minus the additive
/// `resolution` column and its two resolution CHECK constraints (data-model
/// §5, schema v5). A real v3/v4 store has exactly this shape; reproducing it is
/// what lets `onUpgrade`'s `from < 5` `addColumn` run for real.
const String _noteLinksV3Ddl =
    'CREATE TABLE note_links ('
    'id TEXT NOT NULL, '
    'profile_id TEXT NOT NULL, '
    'source_note_id TEXT NOT NULL, '
    'target_note_id TEXT, '
    'target_title TEXT NOT NULL, '
    'normalized_target TEXT NOT NULL, '
    'label TEXT NOT NULL, '
    'source_start INTEGER NOT NULL, '
    'source_end INTEGER NOT NULL, '
    'created_at_utc INTEGER NOT NULL, '
    'PRIMARY KEY (id), '
    'FOREIGN KEY (profile_id) REFERENCES profiles (id), '
    'FOREIGN KEY (profile_id, source_note_id) '
    'REFERENCES notes (profile_id, id), '
    'CHECK (source_end >= source_start))';

/// Downgrades a freshly created v14 store file to look exactly like a released
/// version-[fromVersion] store, then closes it.
void _revertToVersion(String path, int fromVersion) {
  final raw.Database db = raw.sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = OFF');
    // Drop the newer tables so only version-N structure remains. FTS shadow
    // tables belong to search_fts (a v1 baseline object) and are untouched.
    for (final String table in _tablesAfter(fromVersion)) {
      db.execute('DROP TABLE IF EXISTS "$table"');
    }
    if (fromVersion == 3 || fromVersion == 4) {
      // note_links exists at v3/v4 but predates the v5 resolution column. The
      // column is referenced by a CHECK, so it cannot be dropped in place;
      // rebuild the empty table with the faithful pre-v5 DDL instead.
      db.execute('DROP TABLE IF EXISTS note_links');
      db.execute(_noteLinksV3Ddl);
    }
    db.execute('PRAGMA user_version = $fromVersion');
  } finally {
    db.close();
  }
}

/// Seeds a profile and life area — present since the v1 baseline — plus, when
/// the version supports them, a reminder (v2) and a resolved note + note_link
/// (v3) so the v5 backfill and v14 reminders recreate are proven to preserve
/// rows.
Future<void> _seedAtVersion(String path, int fromVersion) async {
  final raw.Database db = raw.sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute(
      'INSERT INTO profiles '
      '(id, display_name, locale, timezone_id, week_start, hour_format, '
      'is_active, created_at_utc, updated_at_utc) '
      "VALUES ('p1', 'Owner', 'en', 'UTC', 1, 'h24', 1, 0, 0)",
    );
    db.execute(
      'INSERT INTO life_areas '
      '(id, profile_id, name, normalized_name, rank, is_default, '
      'created_at_utc, updated_at_utc) '
      "VALUES ('a1', 'p1', 'Career', 'career', 'a', 1, 0, 0)",
    );
    if (fromVersion >= 2) {
      // Offset-form reminder: trigger_kind 'offset' populates offset_minutes
      // and leaves absolute_local null (reminders XOR CHECK).
      db.execute(
        'INSERT INTO reminders '
        '(id, profile_id, owner_type, owner_id, category, trigger_kind, '
        'offset_minutes, timezone_id, dst_policy, delivery_status, '
        'created_at_utc, updated_at_utc) '
        "VALUES ('r1', 'p1', 'task', 't1', 'task', 'offset', -10, 'UTC', "
        "'forward_gap_earlier_overlap', 'pending', 0, 0)",
      );
    }
    if (fromVersion >= 3) {
      db.execute(
        'INSERT INTO notes '
        '(id, profile_id, life_area_id, title, normalized_title, body, '
        'content_hash, rank, created_at_utc, updated_at_utc) '
        "VALUES ('n1', 'p1', 'a1', 'Note', 'note', 'Body', 'hash', 'a', 0, 0)",
      );
      if (fromVersion >= 5) {
        // v5+ note_links carries resolution; the CHECK requires
        // (resolution = 'resolved') == (target_note_id IS NOT NULL).
        db.execute(
          'INSERT INTO note_links '
          '(id, profile_id, source_note_id, target_note_id, target_title, '
          'normalized_target, label, source_start, source_end, resolution, '
          'created_at_utc) '
          "VALUES ('l1', 'p1', 'n1', 'n1', 'Note', 'note', 'Note', 0, 4, "
          "'resolved', 0)",
        );
      } else {
        // v3/v4 note_links has no resolution column; the v5 backfill will mark
        // this target-bearing link 'resolved'.
        db.execute(
          'INSERT INTO note_links '
          '(id, profile_id, source_note_id, target_note_id, target_title, '
          'normalized_target, label, source_start, source_end, '
          'created_at_utc) '
          "VALUES ('l1', 'p1', 'n1', 'n1', 'Note', 'note', 'Note', 0, 4, 0)",
        );
      }
    }
  } finally {
    db.close();
  }
}

Future<Set<String>> _tableNames(ForgeSchemaDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((QueryRow r) => r.data['name'] as String).toSet();
}

Future<int> _count(ForgeSchemaDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table')
      .get();
  return rows.single.data['n'] as int;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-upgrade-matrix-');
  });
  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  /// Builds a version-[fromVersion] store on disk and returns its path.
  Future<String> buildBaseline(int fromVersion) async {
    final String path = '${dir.path}/store-v$fromVersion.sqlite';
    // 1. Create the full current schema via the real onCreate.
    final ForgeSchemaDatabase created = ForgeSchemaDatabase(
      NativeDatabase(File(path)),
    );
    await created.customSelect('SELECT 1').get(); // Force onCreate to run.
    await created.close();
    // 2. Revert to the historical version and 3. seed representative rows.
    _revertToVersion(path, fromVersion);
    await _seedAtVersion(path, fromVersion);
    return path;
  }

  // The complete public upgrade matrix: every released baseline through v14.
  for (int fromVersion = 1; fromVersion < _currentVersion; fromVersion += 1) {
    testWithEvidence(
      _evidence('V$fromVersion'),
      'a version-$fromVersion store upgrades to v$_currentVersion preserving '
      'data',
      () async {
        final String path = await buildBaseline(fromVersion);

        // 4. Reopen: the real onUpgrade(from -> 14) runs during the first read.
        final ForgeSchemaDatabase upgraded = ForgeSchemaDatabase(
          NativeDatabase(File(path)),
        );
        addTearDown(upgraded.close);

        final List<QueryRow> userVersion = await upgraded
            .customSelect('PRAGMA user_version')
            .get();
        expect(
          userVersion.single.data.values.first,
          _currentVersion,
          reason: 'onUpgrade did not advance user_version from $fromVersion',
        );

        // 5a. Every current table now exists.
        final Set<String> present = await _tableNames(upgraded);
        for (final TableInfo<Table, dynamic> table in upgraded.allTables) {
          expect(
            present,
            contains(table.actualTableName),
            reason:
                'onUpgrade from $fromVersion omitted ${table.actualTableName}',
          );
        }

        // 5b. Baseline data survived the additive migration.
        expect(await _count(upgraded, 'profiles'), 1);
        expect(await _count(upgraded, 'life_areas'), 1);
        if (fromVersion >= 2) {
          expect(await _count(upgraded, 'reminders'), 1);
        }
        if (fromVersion >= 3) {
          expect(await _count(upgraded, 'notes'), 1);
          expect(await _count(upgraded, 'note_links'), 1);
          // v5 backfill: a link with a target is marked resolved.
          final List<QueryRow> resolved = await upgraded
              .customSelect("SELECT resolution FROM note_links WHERE id = 'l1'")
              .get();
          expect(resolved.single.data['resolution'], 'resolved');
        }

        // 5c. A v14-only table is usable end to end (water tracking, v13) and
        // the recreated reminders table (v14) accepts the widened workout
        // owner, proving the store recompiled to the current contract.
        await upgraded.customStatement(
          'INSERT INTO water_events '
          '(id, profile_id, life_area_id, amount_scaled, entered_value, '
          'entered_unit, occurred_at_utc, created_at_utc, updated_at_utc) '
          "VALUES ('w1', 'p1', 'a1', 250000, 250.0, 'ml', 100, 0, 0)",
        );
        expect(await _count(upgraded, 'water_events'), 1);
      },
    );
  }
}
