import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart'
    show MigrationLayout;
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/migration_verification.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';

/// Outcome of a successful staged restore.
final class RestoreResult {
  const RestoreResult({
    required this.metadata,
    required this.activatedDirectoryName,
    required this.generationId,
    required this.priorDirectoryName,
  });

  final BackupMetadata metadata;
  final String activatedDirectoryName;
  final String generationId;

  /// The generation that was live before activation, retained for safety, or
  /// null when the install had no prior generation.
  final String? priorDirectoryName;
}

/// Raised when a restore fails. The live generation is always left intact and
/// active; a partially built staging generation is discarded. Every failure is
/// a non-destructive Recovery-Mode signal.
final class RestoreFailure implements Exception {
  const RestoreFailure(this.phase, this.detail);

  /// Redaction-safe phase: `validate`, `metadata`, `stage`, `verify_staging`,
  /// `activation`, or `post_activation_verify`.
  final String phase;
  final String detail;

  @override
  String toString() => 'RestoreFailure($phase: $detail)';
}

/// Restores an FBC1 archive by building a complete, unexposed generation and
/// atomically activating it via the active-generation pointer
/// (`R-BACKUP-003`, `R-BACKUP-004`, design §12).
///
/// The flow mirrors the migration engine's staged-generation/atomic-activation
/// primitives and reuses the same [ActiveGenerationPointer] and
/// [MigrationConnectionOpener]:
///
/// 1. Bounded authenticated validation of the archive before any file is
///    written (truncation/reorder/tamper/malformed all reject).
/// 2. Materialise the archive into a private staging area, then build a fresh
///    unexposed generation directory containing only the restored store.
/// 3. Verify the staged store (integrity, foreign keys, schema version,
///    recorded `commit_seq`, and FTS integrity).
/// 4. One atomic pointer switch activates the staged generation.
/// 5. Post-switch reopen + verify; any failure restores the prior pointer.
///
/// The live store is never mutated. Any failure before the switch deletes the
/// staging generation and leaves the prior generation live; a failure after the
/// switch restores the prior pointer (rollback). Attachments are not restored
/// (V1 excludes remote attachment storage).
final class StagedRestoreService {
  StagedRestoreService({
    required this.layout,
    required this.opener,
    required this.codec,
    required this.idGenerator,
    this.verifier = const MigrationVerifier(),
    this.storeFileName = 'store.sqlite',
    this.logger,
  });

  final MigrationLayout layout;
  final MigrationConnectionOpener opener;
  final Fbc1Codec codec;
  final IdGenerator idGenerator;
  final MigrationVerifier verifier;
  final String storeFileName;
  final StructuredLogger? logger;

  static const String _component = 'backup.restore';

  ActiveGenerationPointer get _pointer =>
      ActiveGenerationPointer(pointerFile: layout.pointerFile);

  Future<RestoreResult> restore({
    required List<int> archive,
    required List<int> passphrase,
  }) async {
    // 1. Bounded authenticated validation before touching any staging state.
    try {
      await codec.validate(passphrase: passphrase, archive: archive);
    } on Fbc1FormatException catch (error) {
      throw RestoreFailure('validate', error.code);
    }

    final ActiveGenerationRecord? prior = await _pointer.read();

    final Directory payloadDir = await Directory.systemTemp.createTemp(
      'forge-backup-restore-',
    );
    final String stagingName = 'generation-${idGenerator.uuidV7()}';
    final Directory stagingDir = Directory(
      layout.generationDirectory(stagingName),
    );
    try {
      // 2. Materialise the archive to a private payload area, authenticating
      //    every frame a second time as it is written.
      final _DirectorySink sink = _DirectorySink(payloadDir);
      try {
        await codec.restore(
          passphrase: passphrase,
          archive: archive,
          sink: sink,
        );
      } on Fbc1FormatException catch (error) {
        throw RestoreFailure('validate', error.code);
      } finally {
        await sink.dispose();
      }

      final BackupMetadata metadata = await _readMetadata(payloadDir);
      final File payloadStore = File(
        '${payloadDir.path}/${metadata.storeFileName}',
      );
      if (!payloadStore.existsSync()) {
        throw const RestoreFailure('metadata', 'store file absent in archive');
      }

      // 2b. Build the unexposed generation directory with only the store.
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
      await stagingDir.create(recursive: true);
      await _copyFile(payloadStore, File('${stagingDir.path}/$storeFileName'));

      // 3. Verify the staged store before it can ever be exposed.
      await _verifyStaged(stagingDir.path, metadata);

      // 4. Atomic activation.
      final String generationId = idGenerator.uuidV7();
      final ActiveGenerationRecord newRecord = ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId(generationId),
          schemaVersion: metadata.schemaVersion,
        ),
        directoryName: stagingName,
      );
      try {
        await _pointer.switchTo(newRecord);
      } on Object catch (error) {
        await _deleteQuietly(stagingDir);
        throw RestoreFailure('activation', error.toString());
      }

      // 5. Post-switch reopen + verify; roll back on any failure.
      try {
        await _verifyActivated(stagingDir.path, metadata);
      } on Object catch (error) {
        await _rollback(prior);
        await _deleteQuietly(stagingDir);
        throw RestoreFailure(
          'post_activation_verify',
          error is RestoreFailure ? error.detail : error.toString(),
        );
      }

      _log(LogLevel.info, 'restored');
      return RestoreResult(
        metadata: metadata,
        activatedDirectoryName: stagingName,
        generationId: generationId,
        priorDirectoryName: prior?.directoryName,
      );
    } on RestoreFailure {
      await _deleteQuietly(stagingDir);
      rethrow;
    } on Object catch (error) {
      // Any non-classified failure before activation (e.g. an I/O error or a
      // crash while opening/verifying the staged store) must still discard the
      // partial staging generation and surface a clean, non-destructive
      // RestoreFailure. The pointer was never switched, so the prior generation
      // remains live and intact (R-BACKUP-004, NFR-REL-002).
      await _deleteQuietly(stagingDir);
      throw RestoreFailure('stage', error.toString());
    } finally {
      await _deleteQuietly(payloadDir);
    }
  }

  Future<BackupMetadata> _readMetadata(Directory payloadDir) async {
    final File metaFile = File('${payloadDir.path}/backup_meta.json');
    if (!metaFile.existsSync()) {
      throw const RestoreFailure('metadata', 'backup_meta.json absent');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await metaFile.readAsString());
    } on FormatException catch (error) {
      throw RestoreFailure('metadata', 'malformed: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const RestoreFailure('metadata', 'not an object');
    }
    try {
      return BackupMetadata.fromJson(decoded);
    } on Object catch (error) {
      throw RestoreFailure('metadata', error.toString());
    }
  }

  Future<void> _verifyStaged(String dir, BackupMetadata metadata) async {
    final MigrationConnection conn = await opener.open(
      dir,
      createIfMissing: false,
    );
    try {
      await _checkIntegrity(conn);
      final List<Map<String, Object?>> fk = await conn.select(
        'PRAGMA foreign_key_check',
      );
      if (fk.isNotEmpty) {
        throw RestoreFailure('verify_staging', 'fk=${fk.length}');
      }
      final int recordedSchema = await conn.scalarInt(
        'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
      );
      if (recordedSchema != metadata.schemaVersion) {
        throw RestoreFailure(
          'verify_staging',
          'schema=$recordedSchema expected=${metadata.schemaVersion}',
        );
      }
      if (await _tableExists(conn, 'commit_log')) {
        final int commitSeq = await conn.scalarInt(
          'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
        );
        if (commitSeq != metadata.commitSeq) {
          throw RestoreFailure(
            'verify_staging',
            'commit_seq=$commitSeq expected=${metadata.commitSeq}',
          );
        }
      }
      final FtsIntegrityReport fts = await const FtsIntegrityVerifier().verify(
        conn,
      );
      if (!fts.passed) {
        throw RestoreFailure('verify_staging', 'fts:${fts.failures.first}');
      }
    } finally {
      await conn.dispose();
    }
  }

  Future<void> _verifyActivated(String dir, BackupMetadata metadata) async {
    final MigrationConnection conn = await opener.open(
      dir,
      createIfMissing: false,
    );
    try {
      await _checkIntegrity(conn);
      final int recordedSchema = await conn.scalarInt(
        'SELECT schema_version AS v FROM schema_metadata WHERE id = 1',
      );
      if (recordedSchema != metadata.schemaVersion) {
        throw RestoreFailure(
          'post_activation_verify',
          'schema=$recordedSchema expected=${metadata.schemaVersion}',
        );
      }
    } finally {
      await conn.dispose();
    }
  }

  Future<void> _checkIntegrity(MigrationConnection conn) async {
    final List<Map<String, Object?>> integrity = await conn.select(
      'PRAGMA integrity_check',
    );
    final String result = integrity.isEmpty
        ? 'empty'
        : integrity.first.values.first.toString();
    if (result != 'ok') {
      throw RestoreFailure('verify_staging', 'integrity=$result');
    }
  }

  Future<void> _rollback(ActiveGenerationRecord? prior) async {
    if (prior != null) {
      await _pointer.switchTo(prior);
    } else if (layout.pointerFile.existsSync()) {
      await layout.pointerFile.delete();
    }
    _log(LogLevel.warning, 'rolled_back_restore');
  }

  Future<bool> _tableExists(MigrationConnection conn, String name) async {
    final List<Map<String, Object?>> rows = await conn.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[name],
    );
    return rows.isNotEmpty;
  }

  Future<void> _copyFile(File from, File to) async {
    final IOSink sink = to.openWrite();
    try {
      await sink.addStream(from.openRead());
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<void> _deleteQuietly(Directory dir) async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  void _log(LogLevel level, String eventCode) {
    logger?.log(level: level, component: _component, eventCode: eventCode);
  }
}

/// Streams authenticated file chunks straight to disk under [root], keeping
/// restore memory-bounded. Paths are already validated by the codec.
final class _DirectorySink implements Fbc1FileSink {
  _DirectorySink(this.root);

  final Directory root;

  /// Owned across begin/end/dispose; always closed in `end`/`dispose`.
  // ignore: close_sinks
  IOSink? _sink;

  @override
  Future<void> begin(String path, int fileSize) async {
    final File file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    _sink = file.openWrite();
  }

  @override
  Future<void> chunk(String path, Uint8List bytes) async {
    _sink!.add(bytes);
  }

  @override
  Future<void> end(String path) async {
    final IOSink? sink = _sink;
    if (sink != null) {
      await sink.flush();
      await sink.close();
      _sink = null;
    }
  }

  Future<void> dispose() async {
    final IOSink? sink = _sink;
    if (sink != null) {
      await sink.close();
      _sink = null;
    }
  }
}
