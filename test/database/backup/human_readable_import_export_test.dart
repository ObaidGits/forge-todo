import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/portable_tables.dart';
import 'package:forge/features/backup/infrastructure/human_readable_export.dart';
import 'package:forge/features/backup/infrastructure/human_readable_import.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'human_readable_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-HUMAN-IO-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.6'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-005'),
    RequirementId('R-GEN-003'),
  ],
);

void main() {
  late Directory root;
  late Sqlite3MigrationConnectionOpener opener;

  String genDir(String name) => '${root.path}/$name';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-human-io-');
    opener = Sqlite3MigrationConnectionOpener();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> seed(
    String name, {
    int areas = 2,
    int tasks = 3,
    bool withDeletedTask = false,
  }) async {
    final conn = await opener.open(genDir(name), createIfMissing: true);
    await seedPortableStore(
      conn,
      areas: areas,
      tasks: tasks,
      withDeletedTask: withDeletedTask,
    );
    await conn.dispose();
  }

  HumanReadableExporter exporter() => HumanReadableExporter(
    opener: opener,
    now: () => DateTime.utc(2026, 5, 1),
  );

  HumanReadableImporter importer({IdGenerator? ids}) => HumanReadableImporter(
    opener: opener,
    idGenerator: ids ?? FakeIdGenerator.sequential(),
  );

  for (final HumanReadableFormat format in HumanReadableFormat.values) {
    testWithEvidence(
      _evidence('EXPORT-INTO-EMPTY-${format.id.toUpperCase()}'),
      'exporting from a store then importing into an empty store reproduces '
      'the same portable rows (${format.id})',
      () async {
        await seed('source', areas: 2, tasks: 3);
        final HumanReadableExportResult export = await exporter().export(
          generationDirectory: genDir('source'),
          format: format,
        );

        // Fresh empty target with the same schema, no rows.
        await seed('target', areas: 0, tasks: 0);
        // Remove the seeded areas/tasks are already zero; ensure empty.
        final HumanReadableImporter imp = importer();
        final HumanReadableImportPreview preview = await imp.preview(
          generationDirectory: genDir('target'),
          bytes: export.bytes,
          format: format,
        );
        // Nothing collides in an empty target.
        expect(preview.plan.hasRemaps, isFalse);
        expect(preview.plan.addedCount, 5); // 2 areas + 3 tasks
        final HumanReadableImportResult result = await imp.commit(
          generationDirectory: genDir('target'),
          preview: preview,
        );
        expect(result.insertedCount, 5);

        final conn = await opener.open(
          genDir('target'),
          createIfMissing: false,
        );
        final int areaCount = await conn.countRows('life_areas');
        final int taskCount = await conn.countRows('tasks');
        await conn.dispose();
        expect(areaCount, 2);
        expect(taskCount, 3);
      },
    );
  }

  testWithEvidence(
    _evidence('COLLISION-REMAP-COMMIT'),
    'importing colliding rows remaps them and rewrites child references so '
    'links stay intact and nothing is overwritten',
    () async {
      // Source has area-0 + task-0 referencing it.
      await seed('source', areas: 1, tasks: 1);
      final HumanReadableExportResult export = await exporter().export(
        generationDirectory: genDir('source'),
        format: HumanReadableFormat.json,
      );

      // Target already has DIFFERENT content under the same IDs.
      final conn = await opener.open(genDir('target'), createIfMissing: true);
      await seedPortableStore(conn, areas: 0, tasks: 0);
      await conn.execute(
        'INSERT INTO life_areas (id, profile_id, name, rank, deleted_at_utc) '
        'VALUES (?, ?, ?, ?, NULL)',
        <Object?>['area-0', 'profile-1', 'Existing area', 'z0'],
      );
      await conn.execute(
        'INSERT INTO tasks (id, profile_id, life_area_id, title, note_id, '
        'deleted_at_utc) VALUES (?, ?, ?, ?, NULL, NULL)',
        <Object?>['task-0', 'profile-1', 'area-0', 'Existing task'],
      );
      await conn.dispose();

      final HumanReadableImporter imp = importer(
        ids: FakeIdGenerator(<String>[
          '018f0000-0000-7000-8000-000000000001',
          '018f0000-0000-7000-8000-000000000002',
        ]),
      );
      final HumanReadableImportPreview preview = await imp.preview(
        generationDirectory: genDir('target'),
        bytes: export.bytes,
        format: HumanReadableFormat.json,
      );
      expect(preview.plan.collisionRemapCount, 2);
      await imp.commit(generationDirectory: genDir('target'), preview: preview);

      final check = await opener.open(genDir('target'), createIfMissing: false);
      // Existing rows are untouched (never overwritten).
      final existingArea = await check.select(
        "SELECT name FROM life_areas WHERE id = 'area-0'",
      );
      expect(existingArea.single['name'], 'Existing area');
      // Imported area landed on the remapped ID.
      final newArea = await check.select(
        "SELECT name FROM life_areas WHERE id = "
        "'018f0000-0000-7000-8000-000000000001'",
      );
      expect(newArea.single['name'], 'Area 0');
      // The imported task's life_area_id was rewritten to the remapped area ID.
      final newTask = await check.select(
        "SELECT life_area_id FROM tasks WHERE id = "
        "'018f0000-0000-7000-8000-000000000002'",
      );
      expect(
        newTask.single['life_area_id'],
        '018f0000-0000-7000-8000-000000000001',
      );
      await check.dispose();
    },
  );

  testWithEvidence(
    _evidence('TOMBSTONE-NO-RESURRECT'),
    'importing a row whose ID matches a local tombstone never resurrects the '
    'deleted record; it is inserted under a fresh ID',
    () async {
      // Source: a live task-deleted (as if it exists elsewhere).
      final src = await opener.open(genDir('source'), createIfMissing: true);
      await seedPortableStore(src, areas: 1, tasks: 0);
      await src.execute(
        'INSERT INTO tasks (id, profile_id, life_area_id, title, note_id, '
        'deleted_at_utc) VALUES (?, ?, ?, ?, NULL, NULL)',
        <Object?>['task-deleted', 'profile-1', 'area-0', 'Revived?'],
      );
      await src.dispose();
      final HumanReadableExportResult export = await exporter().export(
        generationDirectory: genDir('source'),
        format: HumanReadableFormat.json,
      );

      // Target: task-deleted is a tombstone.
      await seed('target', areas: 1, tasks: 0, withDeletedTask: true);

      final HumanReadableImporter imp = importer(
        ids: FakeIdGenerator(<String>['018f0000-0000-7000-8000-0000000000aa']),
      );
      final HumanReadableImportPreview preview = await imp.preview(
        generationDirectory: genDir('target'),
        bytes: export.bytes,
        format: HumanReadableFormat.json,
      );
      expect(preview.plan.tombstoneBlockedCount, 1);
      await imp.commit(generationDirectory: genDir('target'), preview: preview);

      final check = await opener.open(genDir('target'), createIfMissing: false);
      // The tombstone is still a tombstone (never revived).
      final tomb = await check.select(
        "SELECT deleted_at_utc FROM tasks WHERE id = 'task-deleted'",
      );
      expect(tomb.single['deleted_at_utc'], isNotNull);
      // The incoming live row exists only under the fresh remapped ID.
      final revived = await check.select(
        "SELECT title, deleted_at_utc FROM tasks WHERE id = "
        "'018f0000-0000-7000-8000-0000000000aa'",
      );
      expect(revived.single['title'], 'Revived?');
      expect(revived.single['deleted_at_utc'], isNull);
      await check.dispose();
    },
  );

  testWithEvidence(
    _evidence('EXACT-REIMPORT-NO-DUP'),
    're-importing an identical export into the same store adds nothing',
    () async {
      await seed('store', areas: 2, tasks: 3);
      final HumanReadableExportResult export = await exporter().export(
        generationDirectory: genDir('store'),
        format: HumanReadableFormat.json,
      );
      final HumanReadableImporter imp = importer();
      final HumanReadableImportPreview preview = await imp.preview(
        generationDirectory: genDir('store'),
        bytes: export.bytes,
        format: HumanReadableFormat.json,
      );
      expect(preview.plan.exactMatchCount, 5);
      final HumanReadableImportResult result = await imp.commit(
        generationDirectory: genDir('store'),
        preview: preview,
      );
      expect(result.insertedCount, 0);

      final conn = await opener.open(genDir('store'), createIfMissing: false);
      expect(await conn.countRows('tasks'), 3);
      expect(await conn.countRows('life_areas'), 2);
      await conn.dispose();
    },
  );

  testWithEvidence(
    _evidence('EXPORT-EXCLUDES-TOMBSTONES'),
    'a human-readable export excludes tombstoned rows by default',
    () async {
      await seed('store', areas: 1, tasks: 2, withDeletedTask: true);
      final HumanReadableExportResult export = await exporter().export(
        generationDirectory: genDir('store'),
        format: HumanReadableFormat.json,
      );
      final ExportTable tasks = export.document.table('tasks')!;
      expect(tasks.rows.length, 2);
      expect(
        tasks.rows.every((Map<String, String?> r) => r['id'] != 'task-deleted'),
        isTrue,
      );
    },
  );

  testWithEvidence(
    _evidence('PORTABLE-TABLES-CONFIG'),
    'the default portable table set keys on id and tombstones on deleted_at_utc',
    () {
      final PortableTable tasks = defaultPortableTables.firstWhere(
        (PortableTable t) => t.name == 'tasks',
      );
      expect(tasks.primaryKeyColumn, 'id');
      expect(tasks.tombstoneColumn, 'deleted_at_utc');
      // Recovery source labels are stable identifiers.
      expect(RecoverySource.userBackup.id, 'user_backup');
    },
  );
}
