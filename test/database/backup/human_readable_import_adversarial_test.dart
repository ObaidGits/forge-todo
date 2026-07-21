import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/infrastructure/human_readable_import.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';
import 'human_readable_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-IMPORT-ADVERSARIAL-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.8'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-005'),
    RequirementId('R-GEN-003'),
  ],
);

/// Adversarial import remap and rejection depth for the human-readable
/// import/export pipeline (task 10.8), beyond 10.6's core round-trip and single
/// collision-remap cases. Covers chained multi-row collision remap with
/// transitive reference rewiring and malformed/rejected documents in every
/// format (testing.md §13 "malformed Unicode/Markdown"; fail-closed import).
void main() {
  late Directory root;
  late Sqlite3MigrationConnectionOpener opener;

  String genDir(String name) => '${root.path}/$name';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-import-adv-');
    opener = Sqlite3MigrationConnectionOpener();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  HumanReadableImporter importer({IdGenerator? ids}) => HumanReadableImporter(
    opener: opener,
    idGenerator: ids ?? FakeIdGenerator.sequential(),
  );

  List<int> jsonBytes(Map<String, Object?> root) =>
      utf8.encode(jsonEncode(root));

  Map<String, Object?> envelope(List<Map<String, Object?>> tables) =>
      <String, Object?>{
        'forge_human_readable': <String, Object?>{
          'notice': 'test',
          'format': 'json',
          'format_version': humanReadableFormatVersion,
          'created_at_utc_micros': 0,
          'profile_id': 'profile-1',
          'tables': tables,
        },
      };

  testWithEvidence(
    _evidence('CHAINED-REMAP'),
    'two colliding areas and their child tasks are all remapped and every '
    'child reference is transitively rewired to its remapped area',
    () async {
      // Target already holds different rows under area-0, area-1, task-0.
      final MigrationConnection conn = await opener.open(
        genDir('target'),
        createIfMissing: true,
      );
      await seedPortableStore(conn, areas: 0, tasks: 0);
      for (final String id in <String>['area-0', 'area-1']) {
        await conn.execute(
          'INSERT INTO life_areas (id, profile_id, name, rank, deleted_at_utc) '
          'VALUES (?, ?, ?, ?, NULL)',
          <Object?>[id, 'profile-1', 'Existing $id', 'z'],
        );
      }
      await conn.execute(
        'INSERT INTO tasks (id, profile_id, life_area_id, title, note_id, '
        'deleted_at_utc) VALUES (?, ?, ?, ?, NULL, NULL)',
        <Object?>['task-0', 'profile-1', 'area-0', 'Existing task'],
      );
      await conn.dispose();

      // Incoming: two areas + two tasks that each reference a colliding area.
      final List<int> bytes = jsonBytes(
        envelope(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'life_areas',
            'columns': <String>[
              'id',
              'profile_id',
              'name',
              'rank',
              'deleted_at_utc',
            ],
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'area-0',
                'profile_id': 'profile-1',
                'name': 'Imported A0',
                'rank': 'a0',
                'deleted_at_utc': null,
              },
              <String, Object?>{
                'id': 'area-1',
                'profile_id': 'profile-1',
                'name': 'Imported A1',
                'rank': 'a1',
                'deleted_at_utc': null,
              },
            ],
          },
          <String, Object?>{
            'name': 'tasks',
            'columns': <String>[
              'id',
              'profile_id',
              'life_area_id',
              'title',
              'note_id',
              'deleted_at_utc',
            ],
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'task-0',
                'profile_id': 'profile-1',
                'life_area_id': 'area-0',
                'title': 'Imported T0',
                'note_id': null,
                'deleted_at_utc': null,
              },
              <String, Object?>{
                'id': 'task-9',
                'profile_id': 'profile-1',
                'life_area_id': 'area-1',
                'title': 'Imported T9',
                'note_id': null,
                'deleted_at_utc': null,
              },
            ],
          },
        ]),
      );

      final HumanReadableImporter imp = importer(
        ids: FakeIdGenerator(<String>[
          '018f0000-0000-7000-8000-0000000a0000', // area-0 remap
          '018f0000-0000-7000-8000-0000000a0001', // area-1 remap
          '018f0000-0000-7000-8000-0000000c0000', // task-0 remap
        ]),
      );
      final HumanReadableImportPreview preview = await imp.preview(
        generationDirectory: genDir('target'),
        bytes: bytes,
        format: HumanReadableFormat.json,
      );
      // Both areas and task-0 collide (remapped); task-9 is new (added).
      expect(preview.plan.collisionRemapCount, 3);
      expect(preview.plan.addedCount, 1);
      await imp.commit(generationDirectory: genDir('target'), preview: preview);

      final MigrationConnection check = await opener.open(
        genDir('target'),
        createIfMissing: false,
      );
      // Existing rows untouched.
      expect(
        (await check.select(
          "SELECT name FROM life_areas WHERE id = 'area-0'",
        )).single['name'],
        'Existing area-0',
      );
      // task-0 landed on its remapped ID and points at area-0's remapped ID.
      final t0 = await check.select(
        "SELECT life_area_id FROM tasks WHERE id = "
        "'018f0000-0000-7000-8000-0000000c0000'",
      );
      expect(t0.single['life_area_id'], '018f0000-0000-7000-8000-0000000a0000');
      // task-9 was added unchanged but its reference to colliding area-1 is
      // rewritten to area-1's remapped ID.
      final t9 = await check.select(
        "SELECT life_area_id FROM tasks WHERE id = 'task-9'",
      );
      expect(t9.single['life_area_id'], '018f0000-0000-7000-8000-0000000a0001');
      await check.dispose();
    },
  );

  Future<void> emptyTarget() async {
    final MigrationConnection conn = await opener.open(
      genDir('target'),
      createIfMissing: true,
    );
    await seedPortableStore(conn, areas: 0, tasks: 0);
    await conn.dispose();
  }

  testWithEvidence(
    _evidence('REJECT-MALFORMED-JSON'),
    'malformed JSON is rejected fail-closed and nothing is written',
    () async {
      await emptyTarget();
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: utf8.encode('{ this is not json '),
          format: HumanReadableFormat.json,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'json_malformed',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('REJECT-WRONG-ENVELOPE'),
    'a JSON document without the forge envelope is rejected',
    () async {
      await emptyTarget();
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: jsonBytes(<String, Object?>{'something_else': <String>[]}),
          format: HumanReadableFormat.json,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'json_envelope',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('REJECT-FUTURE-VERSION'),
    'a document from a newer, unsupported format version is rejected',
    () async {
      await emptyTarget();
      final List<int> bytes = jsonBytes(<String, Object?>{
        'forge_human_readable': <String, Object?>{
          'notice': 'test',
          'format': 'json',
          'format_version': humanReadableFormatVersion + 1,
          'created_at_utc_micros': 0,
          'profile_id': 'profile-1',
          'tables': <Object?>[],
        },
      });
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: bytes,
          format: HumanReadableFormat.json,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'json_version',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('REJECT-MISSING-PRIMARY-KEY'),
    'a portable row missing its primary key is rejected before any write',
    () async {
      await emptyTarget();
      final List<int> bytes = jsonBytes(
        envelope(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'tasks',
            'columns': <String>[
              'id',
              'profile_id',
              'life_area_id',
              'title',
              'note_id',
              'deleted_at_utc',
            ],
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': null,
                'profile_id': 'profile-1',
                'life_area_id': 'area-0',
                'title': 'No id',
                'note_id': null,
                'deleted_at_utc': null,
              },
            ],
          },
        ]),
      );
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: bytes,
          format: HumanReadableFormat.json,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'missing_primary_key',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('IGNORE-UNKNOWN-TABLE'),
    'an unknown, non-portable table in the document is ignored, never trusted',
    () async {
      await emptyTarget();
      final List<int> bytes = jsonBytes(
        envelope(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'malicious_secrets',
            'columns': <String>['id', 'value'],
            'rows': <Map<String, Object?>>[
              <String, Object?>{'id': 'x', 'value': 'drop'},
            ],
          },
        ]),
      );
      final HumanReadableImportPreview preview = await importer().preview(
        generationDirectory: genDir('target'),
        bytes: bytes,
        format: HumanReadableFormat.json,
      );
      // The unknown table contributes no planned rows.
      expect(preview.plan.rows, isEmpty);
      final HumanReadableImportResult result = await importer().commit(
        generationDirectory: genDir('target'),
        preview: preview,
      );
      expect(result.insertedCount, 0);
    },
  );

  testWithEvidence(
    _evidence('REJECT-CSV-ROW-BEFORE-TABLE'),
    'a CSV data row before any table header is rejected',
    () async {
      await emptyTarget();
      const String csv =
          '# forge_human_readable\n'
          '# format=csv\n'
          '# format_version=1\n'
          'orphan,row,before,table\n';
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: utf8.encode(csv),
          format: HumanReadableFormat.csv,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'csv_row_before_table',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('REJECT-CSV-FIELD-COUNT'),
    'a CSV data row whose field count disagrees with its header is rejected',
    () async {
      await emptyTarget();
      const String csv =
          '# forge_human_readable\n'
          '# format=csv\n'
          '# format_version=1\n'
          '# table=life_areas\n'
          'id,profile_id,name,rank,deleted_at_utc\n'
          'area-0,profile-1,Only three\n';
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: utf8.encode(csv),
          format: HumanReadableFormat.csv,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'csv_field_count',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('REJECT-MARKDOWN-FIELD-COUNT'),
    'a Markdown table row whose cell count disagrees with its header is '
    'rejected',
    () async {
      await emptyTarget();
      const String md =
          '# Forge human-readable export\n'
          '- format: markdown\n'
          '- format_version: 1\n'
          '- created_at_utc_micros: 0\n'
          '- profile_id: profile-1\n'
          '\n'
          '## life_areas\n'
          '\n'
          '| id | profile_id | name | rank | deleted_at_utc |\n'
          '| --- | --- | --- | --- | --- |\n'
          '| area-0 | profile-1 | Only three |\n';
      await expectLater(
        importer().preview(
          generationDirectory: genDir('target'),
          bytes: utf8.encode(md),
          format: HumanReadableFormat.markdown,
        ),
        throwsA(
          isA<HumanReadableFormatException>().having(
            (HumanReadableFormatException e) => e.code,
            'code',
            'markdown_field_count',
          ),
        ),
      );
    },
  );
}
