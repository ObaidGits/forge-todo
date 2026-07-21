import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/database_runtime.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/helpers.dart';
import '../schema/schema_test_database.dart';

/// Wave 12 release gate (task 12.6): **clean-install** automation.
///
/// A fresh install must initialise the store/schema correctly from empty. This
/// exercises the two halves of the cold-start path with no forking of existing
/// machinery:
///
/// * the **schema `onCreate` path** over the real Drift `ForgeSchemaDatabase`
///   (design §12, data-model §5) — every declared table and the FTS5 index are
///   created, the recorded schema version is the current v14, and referential
///   integrity is enforced from the first read; and
/// * the **runtime bootstrap** over the real [ForgeDatabaseRuntimeFactory] —
///   a fresh install with no pointer provisions exactly one generation,
///   publishes the [ActiveGenerationPointer] only after the store verifies, and
///   comes up `ready` serving a unit of work.
///
/// Live encrypted-cipher provisioning on a device is isolated as MANUAL/CI
/// (there is no native cipher in the host test target); the fake opener models
/// a verified store exactly as the runtime lifecycle suites do.
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-CLEAN-INSTALL-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.6'),
  requirements: <RequirementId>[
    RequirementId('NFR-MAIN-004'),
    RequirementId('NFR-REL-002'),
  ],
);

Future<Set<String>> _sqliteTableNames(ForgeSchemaDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type IN ('table') "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((QueryRow r) => r.data['name'] as String).toSet();
}

void main() {
  group('given a fresh install when the schema onCreate path runs', () {
    late ForgeSchemaDatabase db;

    setUp(() => db = openSchemaDatabase());
    tearDown(() async => db.close());

    testWithEvidence(
      _evidence('SCHEMA'),
      'every declared table plus the FTS5 index is created at current v14',
      () async {
        // Drift records the current schema version via PRAGMA user_version.
        expect(db.schemaVersion, 14);
        final List<QueryRow> userVersion = await db
            .customSelect('PRAGMA user_version')
            .get();
        expect(userVersion.single.data.values.first, 14);

        final Set<String> present = await _sqliteTableNames(db);
        // Every Drift-declared table exists in the freshly created store.
        for (final TableInfo<Table, dynamic> table in db.allTables) {
          expect(
            present,
            contains(table.actualTableName),
            reason: 'onCreate omitted table ${table.actualTableName}',
          );
        }
        // The FTS5 external-content index is created after its content table.
        expect(present, contains('search_fts'));
        expect(present, contains('search_documents'));
        // The singleton schema-metadata table is provisioned.
        expect(present, contains('schema_metadata'));
      },
    );

    testWithEvidence(
      _evidence('CONSTRAINTS'),
      'a freshly created store enforces foreign keys from the first write',
      () async {
        // beforeOpen enables PRAGMA foreign_keys; a dangling reference is
        // rejected, proving the empty store came up fully constrained.
        await expectLater(
          db.customStatement(
            'INSERT INTO devices '
            '(id, profile_id, name, platform, created_at_utc) '
            'VALUES (?, ?, ?, ?, ?)',
            <Object?>['d1', 'ghost-profile', 'Phone', 'android', 0],
          ),
          throwsA(isA<Exception>()),
        );
        // A profile then a device referencing it succeeds.
        final String profile = await insertProfile(db);
        await db.customStatement(
          'INSERT INTO devices '
          '(id, profile_id, name, platform, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>['d1', profile, 'Phone', 'android', 0],
        );
        final List<QueryRow> rows = await db
            .customSelect('SELECT COUNT(*) AS n FROM devices')
            .get();
        expect(rows.single.data['n'], 1);
      },
    );
  });

  group('given a fresh install when the runtime bootstrap runs', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('forge-clean-install-');
    });
    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    ActiveGenerationPointer pointer() => ActiveGenerationPointer(
      pointerFile: File('${dir.path}/active_generation.json'),
    );

    ForgeDatabaseRuntimeFactory factory() => ForgeDatabaseRuntimeFactory(
      paths: DatabaseRuntimePaths(baseDirectory: dir.path),
      // Fresh install: a key exists but no ciphertext has been written yet.
      keyVault: FakeKeyVault.available(<int>[
        1,
        2,
        3,
      ], encryptedStoreExists: false),
      opener: FakeEncryptedStoreOpener(),
      clock: FakeClock(initialUtc: DateTime.utc(2026, 5, 1, 9)),
      monotonicClock: FakeMonotonicClock(bootId: 'boot-clean'),
      idGenerator: FakeIdGenerator.sequential(),
      initialGeneration: DatabaseGeneration(
        id: GenerationId('generation-0001'),
        schemaVersion: 14,
      ),
      processId: 909,
    );

    testWithEvidence(
      _evidence('BOOTSTRAP'),
      'an empty install provisions one generation, sets the pointer, and comes '
      'up ready',
      () async {
        // No pointer exists before the first boot.
        expect(await pointer().read(), isNull);

        final ForgeDatabaseRuntime runtime = await factory().open();
        addTearDown(runtime.dispose);

        // The app comes up: ready and serving a unit of work.
        expect(runtime.state, DatabaseRuntimeState.ready);
        expect(runtime.unitOfWork, isNotNull);
        expect(runtime.activeGeneration.id.value, 'generation-0001');
        expect(runtime.activeGeneration.schemaVersion, 14);

        // The pointer is published only after the store verified.
        final ActiveGenerationRecord? published = await pointer().read();
        expect(published, isNotNull);
        expect(published!.directoryName, 'generation-0001');
        expect(published.generation.schemaVersion, 14);
      },
    );

    testWithEvidence(
      _evidence('REBOOT'),
      'a second boot binds the same provisioned generation without a reset',
      () async {
        final ForgeDatabaseRuntime first = await factory().open();
        final String directory = (await pointer().read())!.directoryName;
        await first.dispose();

        // The second boot now sees existing ciphertext and reuses the pointer.
        final ForgeDatabaseRuntimeFactory rebootFactory =
            ForgeDatabaseRuntimeFactory(
              paths: DatabaseRuntimePaths(baseDirectory: dir.path),
              keyVault: FakeKeyVault.available(<int>[
                1,
                2,
                3,
              ], encryptedStoreExists: true),
              opener: FakeEncryptedStoreOpener(),
              clock: FakeClock(initialUtc: DateTime.utc(2026, 5, 1, 10)),
              monotonicClock: FakeMonotonicClock(bootId: 'boot-clean-2'),
              idGenerator: FakeIdGenerator.sequential(),
              initialGeneration: DatabaseGeneration(
                id: GenerationId('generation-0001'),
                schemaVersion: 14,
              ),
              processId: 910,
            );
        final ForgeDatabaseRuntime second = await rebootFactory.open();
        addTearDown(second.dispose);

        expect(second.state, DatabaseRuntimeState.ready);
        expect((await pointer().read())!.directoryName, directory);
      },
    );
  });
}
