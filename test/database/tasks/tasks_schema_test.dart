import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:sqlite3/common.dart';

import '../schema/schema_test_database.dart';
import 'task_test_support.dart';

/// Real schema / constraint / index tests for the tasks table.
///
/// **Validates: Requirements R-TASK-003, R-TASK-004, R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;
  late String profile;
  late String area;

  setUp(() async {
    db = openSchemaDatabase();
    profile = await insertProfile(db);
    area = await insertLifeArea(db, profile);
  });

  tearDown(() async {
    await db.close();
  });

  final Matcher throwsSqlite = throwsA(isA<SqliteException>());

  Future<void> insertTask(
    String id, {
    String? parent,
    String status = 'open',
    String priority = 'none',
    String? dueDate,
    int? dueAt,
    String? dueTz,
    int? completedAt,
    int? estimate,
    String areaId = 'area-1',
    String rank = 'm',
  }) => db.customStatement(
    'INSERT INTO tasks '
    '(id, profile_id, life_area_id, parent_task_id, title, status, priority, '
    'due_date, due_at_utc, due_timezone, completed_at_utc, estimate_minutes, '
    'rank, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      profile,
      areaId,
      parent,
      'Task $id',
      status,
      priority,
      dueDate,
      dueAt,
      dueTz,
      completedAt,
      estimate,
      rank,
      0,
      0,
    ],
  );

  group('given the due XOR check', () {
    test('then setting both due_date and due_at is rejected', () async {
      await expectLater(
        insertTask('t1', dueDate: '2024-06-01', dueAt: 100, dueTz: 'Etc/UTC'),
        throwsSqlite,
      );
    });

    test('then an instant due without a timezone is rejected', () async {
      await expectLater(insertTask('t1', dueAt: 100), throwsSqlite);
    });

    test('then a date-only due is accepted', () async {
      await insertTask('t1', dueDate: '2024-06-01');
      expect(await _count(db, 'tasks'), 1);
    });

    test('then an instant due with a timezone is accepted', () async {
      await insertTask('t1', dueAt: 100, dueTz: 'Europe/London');
      expect(await _count(db, 'tasks'), 1);
    });
  });

  group('given enum and completion CHECK constraints', () {
    test('then an unknown status is rejected', () async {
      await expectLater(insertTask('t1', status: 'archived'), throwsSqlite);
    });

    test('then an unknown priority is rejected', () async {
      await expectLater(insertTask('t1', priority: 'critical'), throwsSqlite);
    });

    test('then a completed task without completed_at is rejected', () async {
      await expectLater(insertTask('t1', status: 'completed'), throwsSqlite);
    });

    test('then an open task with completed_at is rejected', () async {
      await expectLater(
        insertTask('t1', status: 'open', completedAt: 5),
        throwsSqlite,
      );
    });

    test('then a negative estimate is rejected', () async {
      await expectLater(insertTask('t1', estimate: -1), throwsSqlite);
    });
  });

  group('given the composite parent foreign key', () {
    test('then a subtask under an unknown parent is rejected', () async {
      await expectLater(insertTask('t1', parent: 'ghost'), throwsSqlite);
    });

    test(
      'then a subtask in a different area than its parent is rejected',
      () async {
        await insertLifeArea(
          db,
          profile,
          id: 'area-2',
          normalizedName: 'health',
          isDefault: false,
        );
        await insertTask('parent', areaId: 'area-1');
        await expectLater(
          insertTask('child', parent: 'parent', areaId: 'area-2'),
          throwsSqlite,
        );
      },
    );

    test('then a subtask in the same area is accepted', () async {
      await insertTask('parent');
      await insertTask('child', parent: 'parent', rank: 'n');
      expect(await _count(db, 'tasks'), 2);
    });

    test('then a task cannot be its own parent', () async {
      // The self-parent CHECK fires before the FK.
      await expectLater(
        db.customStatement(
          'INSERT INTO tasks '
          '(id, profile_id, life_area_id, parent_task_id, title, status, '
          'priority, rank, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>['t1', profile, area, 't1', 'x', 'open', 'none', 'm', 0, 0],
        ),
        throwsSqlite,
      );
    });
  });

  group('given the area foreign key', () {
    test('then a task in an unknown area is rejected', () async {
      await expectLater(insertTask('t1', areaId: 'ghost-area'), throwsSqlite);
    });
  });

  group('given measured indexes', () {
    test('then every named task index exists', () async {
      final List<QueryRow> rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final Set<String> names = rows
          .map((QueryRow r) => r.data['name'] as String)
          .toSet();
      for (final String expected in <String>[
        'ux_tasks_profile_id',
        'ux_tasks_area_id',
        'idx_tasks_today',
        'idx_tasks_due_at',
        'idx_tasks_completed',
        'ix_tasks_parent',
      ]) {
        expect(names, contains(expected), reason: 'missing $expected');
      }
    });

    test('then the Today query uses idx_tasks_today', () async {
      final List<QueryRow> rows = await db
          .customSelect(
            'EXPLAIN QUERY PLAN SELECT id FROM tasks '
            "WHERE profile_id = 'p' AND status IN ('open', 'in_progress') "
            'AND deleted_at_utc IS NULL '
            'ORDER BY scheduled_date, due_date, priority, rank, id',
          )
          .get();
      final String plan = rows
          .map((QueryRow r) => r.data['detail'] as String)
          .join(' | ');
      expect(plan, contains('idx_tasks_today'));
    });

    test('then the completed query uses idx_tasks_completed', () async {
      final List<QueryRow> rows = await db
          .customSelect(
            'EXPLAIN QUERY PLAN SELECT id FROM tasks '
            "WHERE profile_id = 'p' AND status = 'completed' "
            'AND deleted_at_utc IS NULL ORDER BY completed_at_utc DESC, id',
          )
          .get();
      final String plan = rows
          .map((QueryRow r) => r.data['detail'] as String)
          .join(' | ');
      expect(plan, contains('idx_tasks_completed'));
    });
  });
}

Future<int> _count(ForgeSchemaDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table')
      .get();
  return rows.single.data['n'] as int;
}
