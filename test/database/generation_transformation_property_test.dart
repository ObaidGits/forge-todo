/// Property 7 — Safe generation transformation.
///
/// > Migration, bootstrap, and restore expose either the prior verified
/// > generation or one fully verified new generation; no ProviderScope observes
/// > mixed resources.
///
/// **Validates: Requirements R-BACKUP-003, R-BACKUP-004, NFR-REL-002**
///
/// This is a generative, fault-injecting property test. It drives the *real*
/// shadow-generation migration engine ([GenerationMigrator]) and the *real*
/// staged FBC1 restore engine ([StagedRestoreService]) over real native-SQLite
/// generation stores, exercising every transformation phase and injecting a
/// failure at each one:
///
/// * migration: `preflight`, `safety_backup`, staging `verify`, and
///   `post_activation_verify`;
/// * restore: archive `validate`, `verify_staging`, and
///   `post_activation_verify`.
///
/// For every generated scenario — regardless of whether the transformation
/// succeeds or is aborted at an injected phase — a *generation-scoped reader*
/// (the test's model of a generation-scoped `ProviderScope`: it resolves the
/// single active-generation pointer, opens the store the pointer references,
/// and observes it) must see exactly one of two coherent states:
///
///   1. the fully-verified prior generation (rollback / no switch), or
///   2. one fully-verified new generation (successful atomic activation),
///
/// and never a blend (partial rows, half-applied schema, missing store, failed
/// integrity, or a pointer that references an intermediate/abandoned shadow
/// directory). A concurrent poller additionally asserts the pointer is never
/// observed referencing anything other than the prior or the final generation
/// while a transformation is in flight.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';
import 'package:forge/features/backup/infrastructure/staged_restore.dart';

import '../helpers/backup_test_crypto.dart';
import '../helpers/helpers.dart';
import '../helpers/migration_harness.dart';
import 'backup/backup_fixtures.dart';
import 'migration/migration_fixtures.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-GENERATION-TRANSFORM-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.10'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-003'),
    RequirementId('R-BACKUP-004'),
    RequirementId('NFR-REL-002'),
  ],
);

/// Fast KDF so hundreds of generated restore round trips stay quick; the FBC1
/// framing, bounds, and authentication are identical regardless of cost.
const Fbc1KdfParameters _fastKdf = Fbc1KdfParameters(
  memoryKiB: 8 * 1024,
  iterations: 1,
);

/// The kind of transformation a generated scenario performs.
enum _Op { migrateAdditive, migrateIncompatible, restore }

/// The phase at which a scenario injects a failure (or [none] for a success
/// run that must activate the new generation).
enum _Fault {
  none,
  preflight,
  safetyBackup,
  verify,
  validate,
  verifyStaging,
  postActivation,
}

/// Faults that are meaningfully injectable for each operation's real phases.
const Map<_Op, List<_Fault>> _applicableFaults = <_Op, List<_Fault>>{
  _Op.migrateAdditive: <_Fault>[_Fault.none],
  _Op.migrateIncompatible: <_Fault>[
    _Fault.none,
    _Fault.preflight,
    _Fault.safetyBackup,
    _Fault.verify,
    _Fault.postActivation,
  ],
  _Op.restore: <_Fault>[
    _Fault.none,
    _Fault.validate,
    _Fault.verifyStaging,
    _Fault.postActivation,
  ],
};

/// Observed facts about whatever generation the active pointer resolves to.
final class _GenerationFacts {
  const _GenerationFacts({
    required this.directoryName,
    required this.schemaVersion,
    required this.itemCount,
    required this.itemColumns,
    required this.statusOpenCount,
    required this.commitSeq,
    required this.integrityOk,
    required this.foreignKeysOk,
  });

  final String directoryName;
  final int schemaVersion;
  final int itemCount;
  final Set<String> itemColumns;
  final int statusOpenCount;
  final int? commitSeq;
  final bool integrityOk;
  final bool foreignKeysOk;

  bool get coherent => integrityOk && foreignKeysOk;

  @override
  String toString() =>
      '_GenerationFacts(dir=$directoryName, schema=$schemaVersion, '
      'items=$itemCount, cols=${(itemColumns.toList()..sort())}, '
      'open=$statusOpenCount, commitSeq=$commitSeq, '
      'integrity=$integrityOk, fk=$foreignKeysOk)';
}

void main() {
  late Directory root;
  late MigrationLayout layout;
  late Sqlite3MigrationConnectionOpener opener;
  late ActiveGenerationPointer pointer;
  const String sourceDirName = 'generation-source';
  final List<int> passphrase = 'correct horse battery staple'.codeUnits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('forge-gen-transform-');
    layout = MigrationLayout(baseDirectory: root.path);
    opener = Sqlite3MigrationConnectionOpener();
    pointer = ActiveGenerationPointer(pointerFile: layout.pointerFile);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  // --- source seeding ------------------------------------------------------

  Future<void> seedMigrationSource(int items) async {
    final MigrationConnection c = await opener.open(
      layout.generationDirectory(sourceDirName),
      createIfMissing: true,
    );
    await createV1Schema(c);
    await seedV1(c, items: items);
    await c.dispose();
    await pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId('gen-source'),
          schemaVersion: 1,
        ),
        directoryName: sourceDirName,
      ),
    );
  }

  Future<int> seedRestoreSource(int items, int commitSeq) async {
    final MigrationConnection c = await opener.open(
      layout.generationDirectory(sourceDirName),
      createIfMissing: true,
    );
    await seedBackupStore(
      c,
      commitSeq: commitSeq,
      generationId: 'gen-source',
      items: items,
      withFts: sqliteHasFts5(),
    );
    await c.dispose();
    await pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId('gen-source'),
          schemaVersion: 1,
        ),
        directoryName: sourceDirName,
      ),
    );
    return commitSeq;
  }

  // --- generation-scoped reader (models a ProviderScope) -------------------

  Future<_GenerationFacts?> observe(
    MigrationConnectionOpener readOpener,
  ) async {
    final ActiveGenerationRecord? rec = await pointer.read();
    if (rec == null) {
      return null;
    }
    final MigrationConnection conn = await readOpener.open(
      layout.generationDirectory(rec.directoryName),
      createIfMissing: false,
    );
    try {
      final List<Map<String, Object?>> integrity = await conn.select(
        'PRAGMA integrity_check',
      );
      final bool integrityOk =
          integrity.isNotEmpty &&
          integrity.first.values.first.toString() == 'ok';
      final List<Map<String, Object?>> fk = await conn.select(
        'PRAGMA foreign_key_check',
      );
      final int schema = await conn.scalarInt(
        'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
      );
      final List<Map<String, Object?>> cols = await conn.select(
        'PRAGMA table_info(items)',
      );
      final Set<String> columns = cols
          .map((Map<String, Object?> r) => r['name']! as String)
          .toSet();
      final int itemCount = await conn.countRows('items');
      final int openCount = columns.contains('status')
          ? await conn.scalarInt(
              "SELECT COUNT(*) AS n FROM items WHERE status = 'open'",
            )
          : 0;
      int? commitSeq;
      final List<Map<String, Object?>> hasCommitLog = await conn.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'commit_log'",
      );
      if (hasCommitLog.isNotEmpty) {
        commitSeq = await conn.scalarInt(
          'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
        );
      }
      return _GenerationFacts(
        directoryName: rec.directoryName,
        schemaVersion: schema,
        itemCount: itemCount,
        itemColumns: columns,
        statusOpenCount: openCount,
        commitSeq: commitSeq,
        integrityOk: integrityOk,
        foreignKeysOk: fk.isEmpty,
      );
    } finally {
      await conn.dispose();
    }
  }

  // --- classification: prior | target | mixed ------------------------------

  // Returns 'prior', 'target', or a mixed/blended description for failure.
  String classify(_Op op, _GenerationFacts f, int items, int? commitSeq) {
    switch (op) {
      case _Op.migrateAdditive:
        final bool prior =
            f.schemaVersion == 1 &&
            f.itemCount == items &&
            f.itemColumns.contains('title') &&
            !f.itemColumns.contains('priority');
        final bool target =
            f.schemaVersion == 2 &&
            f.itemCount == items &&
            f.itemColumns.contains('title') &&
            f.itemColumns.contains('priority');
        if (prior) {
          return 'prior';
        }
        if (target) {
          return 'target';
        }
        return 'mixed';
      case _Op.migrateIncompatible:
        final bool prior =
            f.schemaVersion == 1 &&
            f.itemCount == items &&
            f.itemColumns.contains('title') &&
            !f.itemColumns.contains('name');
        final bool target =
            f.schemaVersion == 3 &&
            f.itemCount == items &&
            f.itemColumns.contains('name') &&
            f.itemColumns.contains('status') &&
            !f.itemColumns.contains('title') &&
            f.statusOpenCount == items;
        if (prior) {
          return 'prior';
        }
        if (target) {
          return 'target';
        }
        return 'mixed';
      case _Op.restore:
        // Restore reproduces the source content into a (possibly new)
        // generation; prior and target share the same content signature, so a
        // coherent generation is defined by schema + item count + commit_seq.
        final bool coherentContent =
            f.schemaVersion == 1 &&
            f.itemCount == items &&
            f.itemColumns.contains('title') &&
            f.commitSeq == commitSeq;
        if (!coherentContent) {
          return 'mixed';
        }
        return f.directoryName == sourceDirName ? 'prior' : 'target';
    }
  }

  // --- the generative sweep ------------------------------------------------

  Future<void> runScenario({
    required int seed,
    required bool observeConcurrently,
  }) async {
    final Random rng = Random(seed);
    final _Op op = _Op.values[rng.nextInt(_Op.values.length)];
    final List<_Fault> faults = _applicableFaults[op]!;
    final _Fault fault = faults[rng.nextInt(faults.length)];
    final int items = rng.nextInt(41); // 0..40, includes the empty edge.
    final int commitSeq = op == _Op.restore ? rng.nextInt(30) : 0;

    final String scenario =
        'seed=$seed op=$op fault=$fault items=$items commitSeq=$commitSeq';

    // Each generated scenario is an independent "install": start from a clean
    // base directory so pointer, journal, backups, and generations never leak
    // between cases.
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await root.create(recursive: true);

    // 1. Seed the source generation and record the prior pointer.
    if (op == _Op.restore) {
      await seedRestoreSource(items, commitSeq);
    } else {
      await seedMigrationSource(items);
    }
    final ActiveGenerationRecord priorPointer = (await pointer.read())!;

    // 2. Build the fault-injecting collaborators for this scenario.
    final BackupTestCrypto crypto = BackupTestCrypto(
      random: Random(seed ^ 0x5f),
    );
    final Fbc1Codec codec = Fbc1Codec(crypto: crypto);
    final FakeDiskSpaceProbe probe = FakeDiskSpaceProbe(
      fault == _Fault.preflight ? 1024 : 8 * 1024 * 1024 * 1024,
    );
    final MigrationConnectionOpener opOpener = fault == _Fault.postActivation
        ? _FailAfterPointerSwitch(opener, layout.pointerFile)
        : opener;

    if (fault == _Fault.safetyBackup) {
      // Occupy the backup root path with a file so creating a backup subdir
      // fails deterministically at the safety-backup phase.
      await File(layout.backupRoot.path).writeAsBytes(<int>[0], flush: true);
    }

    // 3. A concurrent poller models many ProviderScope reads racing the
    //    switch. Whenever the pointer names a generation, that generation must
    //    be complete and internally coherent (never a half-built/blended
    //    store). The engine only ever switches the pointer to a fully-built,
    //    staging-verified generation — including the transient window of a
    //    post-activation rollback — so every distinct observed generation is
    //    validated. A generation the pointer named but that a concurrent
    //    rollback has already discarded is tolerated (a pure read/open race);
    //    the final deterministic reader in step 6 still proves the end state.
    final Set<String> observedNames = <String>{};
    final Set<String> validatedNames = <String>{};
    bool polling = observeConcurrently;
    Future<void> pollFuture = Future<void>.value();
    if (observeConcurrently) {
      pollFuture = () async {
        while (polling) {
          ActiveGenerationRecord? rec;
          try {
            rec = await pointer.read();
          } on Object {
            rec = null;
          }
          if (rec != null && validatedNames.add(rec.directoryName)) {
            observedNames.add(rec.directoryName);
            final String dir = layout.generationDirectory(rec.directoryName);
            final File store = File('$dir/store.sqlite');
            if (store.existsSync()) {
              MigrationConnection? conn;
              try {
                conn = await opener.open(dir, createIfMissing: false);
              } on Object {
                // Vanished between the existence check and the open due to a
                // concurrent rollback discarding the generation. Tolerated.
                if (!store.existsSync()) {
                  conn = null;
                } else {
                  rethrow;
                }
              }
              if (conn != null) {
                try {
                  final List<Map<String, Object?>> integrity = await conn
                      .select('PRAGMA integrity_check');
                  final bool ok =
                      integrity.isNotEmpty &&
                      integrity.first.values.first.toString() == 'ok';
                  final int count = await conn.countRows('items');
                  expect(
                    ok,
                    isTrue,
                    reason:
                        'a ProviderScope observed a BLENDED generation via the '
                        'pointer (integrity check failed) '
                        '($scenario, dir=${rec.directoryName})',
                  );
                  expect(
                    count,
                    items,
                    reason:
                        'a ProviderScope observed a partially populated '
                        'generation via the pointer '
                        '($scenario, dir=${rec.directoryName})',
                  );
                } finally {
                  await conn.dispose();
                }
              }
            }
          }
          await Future<void>.delayed(Duration.zero);
        }
      }();
    }

    // 4. Run the real transformation, capturing whether it aborted.
    Object? thrown;
    String? finalDirName;
    try {
      switch (op) {
        case _Op.migrateAdditive:
          final MigrationOutcome outcome = await _migrator(
            layout: layout,
            opener: opOpener,
            probe: probe,
            registry: MigrationRegistry(<MigrationPlan>[additiveV1toV2()]),
          ).migrateToTarget(targetSchemaVersion: 2);
          finalDirName = outcome.activeDirectoryName;
        case _Op.migrateIncompatible:
          final MigrationOutcome outcome = await _migrator(
            layout: layout,
            opener: opOpener,
            probe: probe,
            registry: buildRegistry(),
            verifier: fault == _Fault.verify
                ? const _AlwaysFailVerifier()
                : const MigrationVerifier(),
          ).migrateToTarget(targetSchemaVersion: 3);
          finalDirName = outcome.activeDirectoryName;
        case _Op.restore:
          final List<int> archive = await _exportSource(
            layout: layout,
            opener: opener,
            codec: codec,
            fault: fault,
          );
          final RestoreResult result = await StagedRestoreService(
            layout: layout,
            opener: opOpener,
            codec: codec,
            idGenerator: FakeIdGenerator.sequential(),
          ).restore(archive: archive, passphrase: passphrase);
          finalDirName = result.activatedDirectoryName;
      }
    } on Object catch (error) {
      thrown = error;
    } finally {
      polling = false;
      await pollFuture;
    }

    // 5. Sanity: a fault scenario must actually have aborted; a `none`
    //    scenario must actually have succeeded. This keeps the fault injection
    //    honest so the property is not vacuously satisfied.
    if (fault == _Fault.none) {
      expect(
        thrown,
        isNull,
        reason:
            'expected a successful transform but it threw: $thrown '
            '($scenario)',
      );
    } else {
      expect(
        thrown,
        isNotNull,
        reason:
            'expected an injected failure at $fault but the transform '
            'succeeded ($scenario)',
      );
    }

    // 6. The generation-scoped reader must observe exactly one coherent
    //    generation: prior on abort, one fully-verified new one on success.
    final _GenerationFacts? facts = await observe(opener);
    expect(
      facts,
      isNotNull,
      reason:
          'the active pointer resolved to nothing after transform '
          '($scenario)',
    );
    expect(
      facts!.coherent,
      isTrue,
      reason:
          'the exposed generation is not internally coherent '
          '(integrity/foreign-key check failed): $facts ($scenario)',
    );

    final int? expectedCommit = op == _Op.restore ? commitSeq : null;
    final String kind = classify(op, facts, items, expectedCommit);
    expect(
      kind,
      isNot('mixed'),
      reason:
          'a ProviderScope observed a BLENDED generation: $facts '
          '($scenario)',
    );

    if (thrown != null) {
      // Aborted: the prior verified generation must remain live.
      expect(
        kind,
        'prior',
        reason:
            'after an aborted transform the reader must see the prior '
            'verified generation, saw $kind: $facts ($scenario)',
      );
      expect(
        facts.directoryName,
        priorPointer.directoryName,
        reason:
            'aborted transform must leave the prior pointer intact '
            '($scenario)',
      );
    } else {
      // Succeeded: one fully-verified new generation must be live.
      expect(
        kind,
        'target',
        reason:
            'after a successful transform the reader must see the fully '
            'verified new generation, saw $kind: $facts ($scenario)',
      );
      if (op != _Op.migrateAdditive) {
        // Shadow migration and restore build a brand-new generation directory.
        expect(
          facts.directoryName,
          isNot(priorPointer.directoryName),
          reason:
              'a successful shadow transform must activate a new '
              'generation directory ($scenario)',
        );
      }
    }

    // 7. The prior generation directory is never destroyed by a transform, so
    //    rollback is always possible and no data is silently reset.
    final MigrationConnection priorConn = await opener.open(
      layout.generationDirectory(priorPointer.directoryName),
      createIfMissing: false,
    );
    try {
      final List<Map<String, Object?>> integrity = await priorConn.select(
        'PRAGMA integrity_check',
      );
      expect(
        integrity.first.values.first.toString(),
        'ok',
        reason:
            'the prior generation must remain intact and openable '
            '($scenario)',
      );
    } finally {
      await priorConn.dispose();
    }

    // 8. Concurrent observations must never have named an intermediate,
    //    still-building step generation. The pointer is only ever switched to
    //    the prior generation or the single final built generation the engine
    //    activates (possibly transiently before a post-activation rollback);
    //    it never exposes an intermediate multi-step shadow directory.
    if (observeConcurrently) {
      final Set<String> allowed = <String>{priorPointer.directoryName};
      if (finalDirName != null) {
        allowed.add(finalDirName);
      }
      // On a post-activation rollback the engine transiently switched to the
      // final built generation before restoring the prior pointer; that single
      // extra name is legitimate (it was a complete, verified generation).
      final Set<String> unexpected = observedNames.difference(allowed);
      expect(
        unexpected.length <= 1,
        isTrue,
        reason:
            'a concurrent reader observed the pointer referencing more '
            'than one non-final generation, which implies an intermediate '
            'shadow directory was exposed: observed=$observedNames '
            'allowed=$allowed ($scenario)',
      );
    }
  }

  testWithEvidence(
    _evidence('PROP-001'),
    'across randomized migration/restore scenarios with failure injected at '
    'every phase, a generation-scoped reader always observes either the prior '
    'verified generation or one fully verified new generation, never a blend',
    () async {
      const int cases = 120;
      for (int seed = 0; seed < cases; seed += 1) {
        // Interleave concurrent-observation runs to exercise the atomic switch
        // being read by a racing ProviderScope.
        await runScenario(seed: seed, observeConcurrently: seed % 4 == 0);
      }
    },
  );

  // --- a few explicit example anchors --------------------------------------

  testWithEvidence(
    _evidence('002'),
    'a successful incompatible migration exposes only the fully verified new '
    'generation',
    () async {
      await seedMigrationSource(15);
      await _migrator(
        layout: layout,
        opener: opener,
        probe: FakeDiskSpaceProbe(8 * 1024 * 1024 * 1024),
        registry: buildRegistry(),
      ).migrateToTarget(targetSchemaVersion: 3);
      final _GenerationFacts facts = (await observe(opener))!;
      expect(facts.coherent, isTrue);
      expect(classify(_Op.migrateIncompatible, facts, 15, null), 'target');
      expect(facts.directoryName, isNot(sourceDirName));
    },
  );

  testWithEvidence(
    _evidence('003'),
    'a verification failure mid-migration leaves only the prior verified '
    'generation exposed',
    () async {
      await seedMigrationSource(15);
      final ActiveGenerationRecord prior = (await pointer.read())!;
      await expectLater(
        _migrator(
          layout: layout,
          opener: opener,
          probe: FakeDiskSpaceProbe(8 * 1024 * 1024 * 1024),
          registry: buildRegistry(),
          verifier: const _AlwaysFailVerifier(),
        ).migrateToTarget(targetSchemaVersion: 3),
        throwsA(isA<MigrationFailure>()),
      );
      final _GenerationFacts facts = (await observe(opener))!;
      expect(facts.coherent, isTrue);
      expect(classify(_Op.migrateIncompatible, facts, 15, null), 'prior');
      expect(facts.directoryName, prior.directoryName);
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a post-activation reopen failure during restore rolls back to the prior '
    'verified generation',
    () async {
      final int commitSeq = await seedRestoreSource(6, 9);
      final ActiveGenerationRecord prior = (await pointer.read())!;
      final Fbc1Codec codec = Fbc1Codec(crypto: BackupTestCrypto());
      final List<int> archive = await _exportSource(
        layout: layout,
        opener: opener,
        codec: codec,
        fault: _Fault.none,
      );
      await expectLater(
        StagedRestoreService(
          layout: layout,
          opener: _FailAfterPointerSwitch(opener, layout.pointerFile),
          codec: codec,
          idGenerator: FakeIdGenerator.sequential(),
        ).restore(archive: archive, passphrase: passphrase),
        throwsA(isA<RestoreFailure>()),
      );
      final _GenerationFacts facts = (await observe(opener))!;
      expect(facts.coherent, isTrue);
      expect(classify(_Op.restore, facts, 6, commitSeq), 'prior');
      expect(facts.directoryName, prior.directoryName);
    },
  );
}

/// Builds a real migrator wired to the given collaborators.
GenerationMigrator _migrator({
  required MigrationLayout layout,
  required MigrationConnectionOpener opener,
  required FakeDiskSpaceProbe probe,
  required MigrationRegistry registry,
  MigrationVerifier verifier = const MigrationVerifier(),
}) => GenerationMigrator(
  layout: layout,
  opener: opener,
  registry: registry,
  preflight: DiskSpacePreflight(probe),
  safetyBackup: SafetyBackup(now: () => DateTime.utc(2024)),
  verifier: verifier,
  idGenerator: FakeIdGenerator.sequential(),
);

/// Exports the live source generation to an FBC1 archive. When [fault] is
/// [_Fault.validate] the sealed archive is tampered so restore rejects it at
/// the validate phase; when [_Fault.verifyStaging] the metadata claims a
/// mismatched schema version so staging verification rejects it.
Future<List<int>> _exportSource({
  required MigrationLayout layout,
  required MigrationConnectionOpener opener,
  required Fbc1Codec codec,
  required _Fault fault,
}) async {
  const String sourceDirName = 'generation-source';
  if (fault == _Fault.verifyStaging) {
    // Re-seal the real store bytes under metadata claiming a wrong schema.
    final File store = File(
      '${layout.generationDirectory(sourceDirName)}/store.sqlite',
    );
    final List<int> storeBytes = await store.readAsBytes();
    final BackupMetadata badMeta = BackupMetadata(
      commitSeq: 0,
      schemaVersion: 999,
      generationId: 'gen-source',
      createdAtUtcMicros: 0,
    );
    return codec.encode(
      passphrase: 'correct horse battery staple'.codeUnits,
      salt: codec.crypto.randomBytes(16),
      kdf: _fastKdf,
      files: <Fbc1File>[
        Fbc1File('backup_meta.json', utf8.encode(jsonEncode(badMeta.toJson()))),
        Fbc1File('store.sqlite', storeBytes),
      ],
    );
  }

  final PointInTimeExporter exporter = PointInTimeExporter(
    opener: opener,
    codec: codec,
    now: () => DateTime.utc(2026),
  );
  final BackupExportResult result = await exporter.export(
    generationDirectory: layout.generationDirectory(sourceDirName),
    passphrase: 'correct horse battery staple'.codeUnits,
    kdf: _fastKdf,
  );
  final List<int> archive = List<int>.of(result.archive);
  if (fault == _Fault.validate) {
    // Flip a byte inside the final (manifest) frame so authentication fails.
    archive[archive.length - 15] ^= 0x01;
  }
  return archive;
}

/// Verifier that always fails, driving the migration post-backfill rollback.
final class _AlwaysFailVerifier extends MigrationVerifier {
  const _AlwaysFailVerifier();

  @override
  Future<VerificationReport> verify({
    required MigrationConnection source,
    required MigrationConnection shadow,
    required List<String> preservedTables,
  }) async => VerificationReport(<VerificationFailure>[
    const VerificationFailure('injected', 'forced failure'),
  ]);
}

/// A real opener that fails the first `createIfMissing: false` open performed
/// *after* the active-generation pointer has changed. That open is precisely
/// the post-activation reopen/verify step, so this drives the rollback branch
/// of both the migrator and the staged restore deterministically without
/// knowing the exact open count in advance.
final class _FailAfterPointerSwitch implements MigrationConnectionOpener {
  _FailAfterPointerSwitch(this._delegate, this._pointerFile);

  final MigrationConnectionOpener _delegate;
  final File _pointerFile;
  String? _initial;

  String _readPointer() =>
      _pointerFile.existsSync() ? _pointerFile.readAsStringSync() : '';

  @override
  Future<MigrationConnection> open(
    String generationDirectory, {
    required bool createIfMissing,
  }) async {
    _initial ??= _readPointer();
    final String current = _readPointer();
    if (!createIfMissing && current != _initial) {
      throw const MigrationConnectionException(
        'injected post-activation open failure',
      );
    }
    return _delegate.open(
      generationDirectory,
      createIfMissing: createIfMissing,
    );
  }
}
