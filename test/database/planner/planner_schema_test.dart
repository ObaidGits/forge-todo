import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/schema/ownership_classification.dart';

import '../schema/schema_test_database.dart';

/// Planner schema ownership classification and composite-key constraints
/// (R-PLAN-001, R-PLAN-003, R-GEN-002; data-model §1).
void main() {
  group('planner ownership classification', () {
    test('[TEST-DB-PLAN-OWNERSHIP][MVP][TASK-5.4][R-GEN-002] '
        'planning tables are classified direct-area and inherited-area', () {
      expect(
        ownershipClassFor('planning_periods'),
        OwnershipClass.directAreaOwner,
      );
      for (final String table in <String>[
        'planning_entries',
        'planning_close_events',
        'planning_close_items',
        'planning_close_adjustments',
      ]) {
        expect(
          ownershipClassFor(table),
          OwnershipClass.inheritedArea,
          reason: '$table must be inherited-area',
        );
      }
    });

    test(
      '[TEST-DB-PLAN-SCHEMA-PRESENT][MVP][TASK-5.4][R-PLAN-001] '
      'every planner table is present and classified in the live schema',
      () async {
        final ForgeSchemaDatabase db = openSchemaDatabase();
        addTearDown(db.close);
        final Set<String> present = db.allTables
            .map((TableInfo<Table, dynamic> t) => t.actualTableName)
            .toSet();
        for (final String table in <String>[
          'planning_periods',
          'planning_entries',
          'planning_close_events',
          'planning_close_items',
          'planning_close_adjustments',
        ]) {
          expect(present, contains(table), reason: '$table missing');
          expect(ownershipClassFor(table), isNotNull);
        }
      },
    );
  });

  group('planner composite-key constraints', () {
    late ForgeSchemaDatabase db;
    late String profileId;

    setUp(() async {
      db = openSchemaDatabase();
      profileId = await insertProfile(db);
      await db.customStatement(
        'INSERT INTO life_areas '
        '(id, profile_id, name, normalized_name, rank, is_default, '
        'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>['area-1', profileId, 'Career', 'career', 'm', 1, 0, 0],
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertPeriod(String id, String key) => db.customStatement(
      'INSERT INTO planning_periods '
      '(id, profile_id, life_area_id, kind, period_key, prompt_version, '
      'revision, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[id, profileId, 'area-1', 'day', key, 1, 1, 0, 0],
    );

    test(
      '[TEST-DB-PLAN-UNIQUE-KEY][MVP][TASK-5.4][R-PLAN-001] '
      'a duplicate (profile, area, kind, period_key) record is rejected',
      () async {
        await insertPeriod('p-1', '2024-06-01');
        await expectLater(
          insertPeriod('p-2', '2024-06-01'),
          throwsA(isA<Object>()),
        );
      },
    );

    test(
      '[TEST-DB-PLAN-SECTION-CHECK][MVP][TASK-5.4][R-PLAN-001] '
      'a week record with a daily section violates the CHECK constraint',
      () async {
        await expectLater(
          db.customStatement(
            'INSERT INTO planning_periods '
            '(id, profile_id, life_area_id, kind, period_key, morning_plan_md, '
            'prompt_version, revision, created_at_utc, updated_at_utc) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'p-bad',
              profileId,
              'area-1',
              'week',
              '2024-W22',
              'not allowed',
              1,
              1,
              0,
              0,
            ],
          ),
          throwsA(isA<Object>()),
        );
      },
    );

    test(
      '[TEST-DB-PLAN-CARRY-CHECK][MVP][TASK-5.4][R-PLAN-003] '
      'a planned entry with a carried_from relation violates the CHECK',
      () async {
        await insertPeriod('p-1', '2024-06-01');
        await expectLater(
          db.customStatement(
            'INSERT INTO planning_entries '
            '(id, profile_id, period_id, entity_type, entity_id, role, '
            'carried_from_entry_id, rank, created_at_utc, updated_at_utc) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'e-bad',
              profileId,
              'p-1',
              'task',
              'task-a',
              'planned',
              'some-entry',
              'n',
              0,
              0,
            ],
          ),
          throwsA(isA<Object>()),
        );
      },
    );

    test(
      '[TEST-DB-PLAN-CARRIED-SUBSET-CHECK][MVP][TASK-5.4][R-PLAN-003] '
      'a close row with carried greater than missed violates the CHECK',
      () async {
        await insertPeriod('p-1', '2024-06-01');
        await expectLater(
          db.customStatement(
            'INSERT INTO planning_close_events '
            '(id, profile_id, period_id, closed_at_utc, boundary_utc, '
            'metric_policy_version, source_commit_seq, eligible_count, '
            'completed_count, missed_count, carried_count, eligible_root_hash, '
            'completed_root_hash, created_at_utc) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'c-bad',
              profileId,
              'p-1',
              0,
              1,
              1,
              0,
              2,
              0,
              1,
              2, // carried (2) > missed (1)
              'x',
              'y',
              0,
            ],
          ),
          throwsA(isA<Object>()),
        );
      },
    );
  });
}
