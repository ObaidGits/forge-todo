import 'dart:io';

import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_journal.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/app/infrastructure/database/migration/resumable_backfill.dart';
import 'package:forge/app/infrastructure/database/migration/safety_backup.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/security/redacting_log.dart';

/// Filesystem layout for migration artifacts. The pointer, journal, and backup
/// root all live outside every generation directory so a generation can be
/// replaced without disturbing them.
final class MigrationLayout {
  const MigrationLayout({
    required this.baseDirectory,
    this.pointerFileName = 'active_generation.json',
    this.journalFileName = 'migration.journal.json',
    this.backupDirectoryName = 'backups',
  });

  final String baseDirectory;
  final String pointerFileName;
  final String journalFileName;
  final String backupDirectoryName;

  String _join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

  File get pointerFile => File(_join(baseDirectory, pointerFileName));

  File get journalFile => File(_join(baseDirectory, journalFileName));

  Directory get backupRoot =>
      Directory(_join(baseDirectory, backupDirectoryName));

  String generationDirectory(String name) => _join(baseDirectory, name);
}

/// How a completed migration resolved.
enum MigrationResult {
  /// The store was already at the requested target version.
  upToDate,

  /// Every step was additive and applied transactionally in place.
  appliedInPlace,

  /// A verified shadow generation was activated atomically.
  activatedShadowGeneration,
}

/// Outcome of [GenerationMigrator.migrateToTarget].
final class MigrationOutcome {
  const MigrationOutcome({
    required this.result,
    required this.fromVersion,
    required this.toVersion,
    this.activeDirectoryName,
    this.safetyBackup,
    this.diskEstimate,
    this.rowsBackfilled = 0,
  });

  final MigrationResult result;
  final int fromVersion;
  final int toVersion;
  final String? activeDirectoryName;
  final SafetyBackupRecord? safetyBackup;
  final DiskSpaceEstimate? diskEstimate;
  final int rowsBackfilled;
}

/// Raised when a migration fails after starting. The prior generation remains
/// live and untouched; the exception is a Recovery-Mode signal.
final class MigrationFailure implements Exception {
  const MigrationFailure(this.phase, this.detail);

  /// Short, redaction-safe phase name (`preflight`, `backfill`, ...).
  final String phase;
  final String detail;

  @override
  String toString() => 'MigrationFailure($phase: $detail)';
}

/// Orchestrates shadow-generation migrations end to end (design §12,
/// data-model §5).
///
/// For an all-additive path the live store is upgraded transactionally in
/// place. For any incompatible path the migrator runs a disk-space preflight,
/// takes an old-client-compatible safety backup, builds one or more *unexposed*
/// generations (schema build + bounded resumable backfill + verification per
/// step), and performs a single atomic pointer switch to the final verified
/// generation. Any failure before the switch leaves the prior generation live
/// and cleans up the abandoned shadow directories; a failure while reopening
/// the new generation restores the prior pointer.
final class GenerationMigrator {
  GenerationMigrator({
    required this.layout,
    required this.opener,
    required this.registry,
    required this.preflight,
    required this.safetyBackup,
    required this.verifier,
    required this.idGenerator,
    ResumableBackfill? backfill,
    this.logger,
  }) : backfill = backfill ?? const ResumableBackfill();

  final MigrationLayout layout;
  final MigrationConnectionOpener opener;
  final MigrationRegistry registry;
  final DiskSpacePreflight preflight;
  final SafetyBackup safetyBackup;
  final MigrationVerifier verifier;
  final IdGenerator idGenerator;
  final ResumableBackfill backfill;
  final StructuredLogger? logger;

  static const String _component = 'database.migration';

  ActiveGenerationPointer get _pointer =>
      ActiveGenerationPointer(pointerFile: layout.pointerFile);

  MigrationJournal get _journal =>
      MigrationJournal(journalFile: layout.journalFile);

  /// Deletes any abandoned shadow directories left by an interrupted migration
  /// and clears the stale journal. The pointer is never touched here.
  ///
  /// Safe to call on every startup before opening the runtime (design §12).
  Future<void> cleanupAbandoned() async {
    final MigrationJournalEntry? entry = await _journal.read();
    if (entry == null) {
      return;
    }
    if (entry.activated) {
      // The switch happened; the journal is merely bookkeeping. Clear it.
      await _journal.clear();
      return;
    }
    for (final String name in entry.createdDirectoryNames) {
      final Directory dir = Directory(layout.generationDirectory(name));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    await _journal.clear();
    _log(LogLevel.warning, 'cleaned_abandoned_migration');
  }

  Future<MigrationOutcome> migrateToTarget({
    required int targetSchemaVersion,
  }) async {
    await cleanupAbandoned();

    final ActiveGenerationRecord? pointer = await _pointer.read();
    if (pointer == null) {
      throw const MigrationFailure(
        'resolve',
        'No active generation pointer; nothing to migrate.',
      );
    }
    final int fromVersion = pointer.generation.schemaVersion;
    if (fromVersion == targetSchemaVersion) {
      return MigrationOutcome(
        result: MigrationResult.upToDate,
        fromVersion: fromVersion,
        toVersion: targetSchemaVersion,
        activeDirectoryName: pointer.directoryName,
      );
    }

    final List<MigrationPlan> chain = registry.path(
      fromVersion: fromVersion,
      toVersion: targetSchemaVersion,
    );
    final bool requiresShadow = chain.any(
      (MigrationPlan plan) => plan.requiresShadowGeneration,
    );

    if (!requiresShadow) {
      return _migrateInPlace(pointer, chain, targetSchemaVersion);
    }
    return _migrateViaShadow(pointer, chain, targetSchemaVersion);
  }

  Future<MigrationOutcome> _migrateInPlace(
    ActiveGenerationRecord pointer,
    List<MigrationPlan> chain,
    int targetSchemaVersion,
  ) async {
    final MigrationConnection connection = await opener.open(
      layout.generationDirectory(pointer.directoryName),
      createIfMissing: false,
    );
    try {
      for (final MigrationPlan plan in chain) {
        await connection.transaction(() async {
          await plan.applyInPlace!(connection);
        });
      }
      await _writeSchemaMetadata(
        connection,
        schemaVersion: targetSchemaVersion,
        generationId: pointer.generation.id.value,
        migrationState: 'active',
      );
    } finally {
      await connection.dispose();
    }
    // Bump the recorded schema version; the directory and generation id are
    // unchanged for a purely additive upgrade.
    await _pointer.switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: pointer.generation.id,
          schemaVersion: targetSchemaVersion,
        ),
        directoryName: pointer.directoryName,
      ),
    );
    _log(LogLevel.info, 'applied_in_place');
    return MigrationOutcome(
      result: MigrationResult.appliedInPlace,
      fromVersion: pointer.generation.schemaVersion,
      toVersion: targetSchemaVersion,
      activeDirectoryName: pointer.directoryName,
    );
  }

  Future<MigrationOutcome> _migrateViaShadow(
    ActiveGenerationRecord pointer,
    List<MigrationPlan> chain,
    int targetSchemaVersion,
  ) async {
    final Directory sourceDir = Directory(
      layout.generationDirectory(pointer.directoryName),
    );

    // 1. Disk-space preflight (source + shadow + WAL/temp + backup + margin).
    final int sourceBytes = await _directoryBytes(sourceDir);
    final DiskSpaceEstimate estimate;
    try {
      estimate = await preflight.ensureCapacity(
        targetPath: layout.baseDirectory,
        sourceBytes: sourceBytes,
        includeBackup: true,
      );
    } on InsufficientDiskSpace catch (error) {
      _log(LogLevel.error, 'preflight_insufficient_disk');
      throw MigrationFailure('preflight', error.toString());
    }

    // 2. Mandatory old-client-compatible safety backup.
    final SafetyBackupRecord backupRecord;
    try {
      backupRecord = await safetyBackup.create(
        sourceGenerationDir: sourceDir,
        backupRoot: layout.backupRoot,
        sourceSchemaVersion: pointer.generation.schemaVersion,
        label: 'to-v$targetSchemaVersion',
      );
    } on Object catch (error) {
      _log(LogLevel.error, 'safety_backup_failed');
      throw MigrationFailure('safety_backup', error.toString());
    }

    // 3. Open the migration journal so an interrupted run is recoverable.
    MigrationJournalEntry journalEntry = MigrationJournalEntry(
      sourceDirectoryName: pointer.directoryName,
      sourceSchemaVersion: pointer.generation.schemaVersion,
      targetSchemaVersion: targetSchemaVersion,
      createdDirectoryNames: const <String>[],
      activated: false,
    );
    await _journal.write(journalEntry);

    // 4. Build each step's unexposed generation in sequence. The source is
    //    never mutated; only the final generation is activated.
    String workingDirName = pointer.directoryName;
    final GenerationId finalGenerationId = GenerationId(idGenerator.uuidV7());
    int rowsBackfilled = 0;
    final List<String> created = <String>[];
    try {
      for (final MigrationPlan plan in chain) {
        final bool isLast = identical(plan, chain.last);
        final String nextName = isLast
            ? 'generation-${finalGenerationId.value}'
            : 'generation-${idGenerator.uuidV7()}';
        created.add(nextName);
        journalEntry = journalEntry.copyWith(createdDirectoryNames: created);
        await _journal.write(journalEntry);

        rowsBackfilled += await _buildStepGeneration(
          plan: plan,
          workingDirName: workingDirName,
          nextDirName: nextName,
          finalSchemaVersion: targetSchemaVersion,
          finalGenerationId: finalGenerationId,
          isLast: isLast,
        );
        workingDirName = nextName;
      }
    } on MigrationFailure {
      await _abortShadow(created);
      await _journal.clear();
      rethrow;
    } on Object catch (error) {
      await _abortShadow(created);
      await _journal.clear();
      throw MigrationFailure('build', error.toString());
    }

    // 5. Atomic activation: switch the pointer to the final verified
    //    generation. The rename is atomic; before it the source is live, after
    //    it the new generation is live.
    final ActiveGenerationRecord newRecord = ActiveGenerationRecord(
      generation: DatabaseGeneration(
        id: finalGenerationId,
        schemaVersion: targetSchemaVersion,
      ),
      directoryName: workingDirName,
    );
    try {
      await _pointer.switchTo(newRecord);
    } on Object catch (error) {
      await _abortShadow(created);
      await _journal.clear();
      throw MigrationFailure('activation', error.toString());
    }

    // 6. Post-switch reopen + verify. If the new generation cannot be trusted,
    //    restore the prior pointer/generation (rollback).
    try {
      await _verifyActivated(newRecord, targetSchemaVersion);
    } on Object catch (error) {
      await _rollbackActivation(pointer, created);
      await _journal.clear();
      throw MigrationFailure('post_activation_verify', error.toString());
    }

    journalEntry = journalEntry.copyWith(
      activated: true,
      finalDirectoryName: workingDirName,
    );
    await _journal.write(journalEntry);
    // Discard intermediate step generations (never the source or the final,
    // now-live generation). The source is retained for rollback safety.
    await _abortShadow(
      created.where((String name) => name != workingDirName).toList(),
    );
    await _journal.clear();
    _log(LogLevel.info, 'activated_shadow_generation');

    return MigrationOutcome(
      result: MigrationResult.activatedShadowGeneration,
      fromVersion: pointer.generation.schemaVersion,
      toVersion: targetSchemaVersion,
      activeDirectoryName: workingDirName,
      safetyBackup: backupRecord,
      diskEstimate: estimate,
      rowsBackfilled: rowsBackfilled,
    );
  }

  /// Builds one step's generation from [workingDirName] into [nextDirName].
  ///
  /// Incompatible step: fresh empty store → build complete target schema →
  /// bounded resumable backfill → verify. Additive step inside a shadow chain:
  /// copy the working store then apply the additive DDL transactionally.
  Future<int> _buildStepGeneration({
    required MigrationPlan plan,
    required String workingDirName,
    required String nextDirName,
    required int finalSchemaVersion,
    required GenerationId finalGenerationId,
    required bool isLast,
  }) async {
    final Directory nextDir = Directory(
      layout.generationDirectory(nextDirName),
    );

    if (!plan.requiresShadowGeneration) {
      // Materialise the additive step into a new generation directory so the
      // source stays untouched until activation.
      await _copyGeneration(
        Directory(layout.generationDirectory(workingDirName)),
        nextDir,
      );
      final MigrationConnection conn = await opener.open(
        nextDir.path,
        createIfMissing: false,
      );
      try {
        await conn.transaction(() async {
          await plan.applyInPlace!(conn);
        });
        if (isLast) {
          await _writeSchemaMetadata(
            conn,
            schemaVersion: finalSchemaVersion,
            generationId: finalGenerationId.value,
            migrationState: 'active',
          );
        }
      } finally {
        await conn.dispose();
      }
      return 0;
    }

    // Incompatible step.
    final MigrationConnection source = await opener.open(
      layout.generationDirectory(workingDirName),
      createIfMissing: false,
    );
    final MigrationConnection shadow = await opener.open(
      nextDir.path,
      createIfMissing: true,
    );
    try {
      await plan.buildTargetSchema!(shadow);
      final BackfillReport report = await backfill.run(
        source: source,
        shadow: shadow,
        tables: plan.backfillTables,
      );
      final List<String> preserved = plan.backfillTables
          .where((BackfillTable t) => t.verifyRowCount)
          .map((BackfillTable t) => t.name)
          .toList(growable: false);
      final VerificationReport verification = await verifier.verify(
        source: source,
        shadow: shadow,
        preservedTables: preserved,
      );
      if (!verification.passed) {
        throw MigrationFailure(
          'verify',
          verification.firstFailure ?? 'unknown',
        );
      }
      if (isLast) {
        await _writeSchemaMetadata(
          shadow,
          schemaVersion: finalSchemaVersion,
          generationId: finalGenerationId.value,
          migrationState: 'active',
        );
      }
      return report.rowsCopied;
    } finally {
      await source.dispose();
      await shadow.dispose();
    }
  }

  Future<void> _verifyActivated(
    ActiveGenerationRecord record,
    int targetSchemaVersion,
  ) async {
    final MigrationConnection conn = await opener.open(
      layout.generationDirectory(record.directoryName),
      createIfMissing: false,
    );
    try {
      final List<Map<String, Object?>> integrity = await conn.select(
        'PRAGMA integrity_check',
      );
      final String result = integrity.isEmpty
          ? 'empty'
          : integrity.first.values.first.toString();
      if (result != 'ok') {
        throw MigrationFailure('post_activation_verify', 'integrity=$result');
      }
      final int recorded = await conn.scalarInt(
        'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
      );
      if (recorded != targetSchemaVersion) {
        throw MigrationFailure(
          'post_activation_verify',
          'schema_metadata=$recorded expected=$targetSchemaVersion',
        );
      }
    } finally {
      await conn.dispose();
    }
  }

  Future<void> _rollbackActivation(
    ActiveGenerationRecord priorPointer,
    List<String> createdDirs,
  ) async {
    // Restore the prior pointer/generation, then discard the shadow set.
    await _pointer.switchTo(priorPointer);
    await _abortShadow(createdDirs);
    _log(LogLevel.warning, 'rolled_back_activation');
  }

  Future<void> _abortShadow(List<String> createdDirs) async {
    for (final String name in createdDirs) {
      final Directory dir = Directory(layout.generationDirectory(name));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  Future<void> _writeSchemaMetadata(
    MigrationConnection conn, {
    required int schemaVersion,
    required String generationId,
    required String migrationState,
  }) async {
    final List<Map<String, Object?>> existing = await conn.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'schema_metadata'",
    );
    if (existing.isEmpty) {
      return;
    }
    await conn.execute(
      'INSERT INTO schema_metadata '
      '(id, schema_version, cipher_version, build_id, generation_id, '
      'migration_state, updated_at_utc) VALUES (1, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'schema_version = excluded.schema_version, '
      'generation_id = excluded.generation_id, '
      'migration_state = excluded.migration_state, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        schemaVersion,
        'pending-adr-0001',
        'migration',
        generationId,
        migrationState,
        0,
      ],
    );
  }

  Future<void> _copyGeneration(Directory from, Directory to) async {
    if (await to.exists()) {
      await to.delete(recursive: true);
    }
    await to.create(recursive: true);
    await for (final FileSystemEntity entity in from.list()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.path.split('/').last;
      final List<int> bytes = await entity.readAsBytes();
      await File('${to.path}/$name').writeAsBytes(bytes, flush: true);
    }
  }

  Future<int> _directoryBytes(Directory dir) async {
    if (!await dir.exists()) {
      return 0;
    }
    int total = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  void _log(LogLevel level, String eventCode) {
    logger?.log(level: level, component: _component, eventCode: eventCode);
  }
}
