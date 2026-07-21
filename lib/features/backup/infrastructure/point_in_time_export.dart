import 'dart:convert';
import 'dart:io';

import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';

/// Immutable description of what a backup captured, embedded in the archive as
/// `backup_meta.json` and reconstructed on restore.
final class BackupMetadata {
  const BackupMetadata({
    required this.commitSeq,
    required this.schemaVersion,
    required this.generationId,
    required this.createdAtUtcMicros,
    this.storeFileName = 'store.sqlite',
    this.excludesAttachments = true,
  });

  /// The single `commit_seq` the snapshot was taken at (`R-BACKUP-001`).
  final int commitSeq;
  final int schemaVersion;
  final String generationId;
  final int createdAtUtcMicros;
  final String storeFileName;

  /// V1 excludes remote attachment storage; local attachment content is out of
  /// scope for this task, so the archive never contains attachment files.
  final bool excludesAttachments;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': 'FBC1',
    'format_version': 1,
    'commit_seq': commitSeq,
    'schema_version': schemaVersion,
    'generation_id': generationId,
    'created_at_utc_micros': createdAtUtcMicros,
    'store_file': storeFileName,
    'excludes_attachments': excludesAttachments,
  };

  static BackupMetadata fromJson(Map<String, Object?> json) {
    if (json['format'] != 'FBC1' || json['format_version'] != 1) {
      throw const BackupExportException('Unrecognised backup metadata.');
    }
    return BackupMetadata(
      commitSeq: json['commit_seq']! as int,
      schemaVersion: json['schema_version']! as int,
      generationId: json['generation_id']! as String,
      createdAtUtcMicros: json['created_at_utc_micros']! as int,
      storeFileName: (json['store_file'] as String?) ?? 'store.sqlite',
      excludesAttachments: (json['excludes_attachments'] as bool?) ?? true,
    );
  }
}

/// Result of a point-in-time export.
final class BackupExportResult {
  const BackupExportResult({
    required this.archive,
    required this.metadata,
    required this.fileCount,
    required this.plaintextBytes,
  });

  final List<int> archive;
  final BackupMetadata metadata;
  final int fileCount;
  final int plaintextBytes;
}

/// Raised when an export cannot produce a trustworthy archive. Never mutates
/// the live store.
final class BackupExportException implements Exception {
  const BackupExportException(this.message);

  final String message;

  @override
  String toString() => 'BackupExportException($message)';
}

/// Produces a point-in-time FBC1 archive of one generation (`R-BACKUP-001`).
///
/// The exporter reads the live generation only; it never writes to it. It
/// resolves the current `commit_seq`, then takes a transactionally consistent
/// SQLite snapshot with `VACUUM INTO` (a read-only operation on the source),
/// and seals the snapshot plus metadata into an authenticated FBC1 container.
///
/// Production runs this with command admission closed / the maintenance gate
/// held (design §12/§13) so no write can advance past the recorded
/// `commit_seq` between reading it and snapshotting. Attachments are excluded:
/// V1 has no remote attachment storage and this task omits local attachment
/// content.
final class PointInTimeExporter {
  PointInTimeExporter({
    required this.opener,
    required this.codec,
    required this.now,
    this.storeFileName = 'store.sqlite',
    this.chunkSize = 1024 * 1024,
    this.logger,
  });

  final MigrationConnectionOpener opener;
  final Fbc1Codec codec;
  final DateTime Function() now;
  final String storeFileName;
  final int chunkSize;
  final StructuredLogger? logger;

  static const String _component = 'backup.export';

  Future<BackupExportResult> export({
    required String generationDirectory,
    required List<int> passphrase,
    Fbc1KdfParameters kdf = const Fbc1KdfParameters(),
  }) async {
    final Directory workDir = await Directory.systemTemp.createTemp(
      'forge-backup-export-',
    );
    final File snapshotFile = File('${workDir.path}/snapshot.sqlite');
    try {
      final MigrationConnection source = await opener.open(
        generationDirectory,
        createIfMissing: false,
      );
      final BackupMetadata metadata;
      try {
        final int commitSeq = await _readCommitSeq(source);
        final _StoreIdentity identity = await _readIdentity(source);
        metadata = BackupMetadata(
          commitSeq: commitSeq,
          schemaVersion: identity.schemaVersion,
          generationId: identity.generationId,
          createdAtUtcMicros: now().toUtc().microsecondsSinceEpoch,
          storeFileName: storeFileName,
        );
        // Transactionally consistent point-in-time snapshot of committed state.
        await source.execute('VACUUM INTO ?', <Object?>[snapshotFile.path]);
      } finally {
        await source.dispose();
      }
      if (!snapshotFile.existsSync()) {
        throw const BackupExportException('Snapshot was not produced.');
      }
      final List<int> storeBytes = await snapshotFile.readAsBytes();
      final List<int> metaBytes = utf8.encode(jsonEncode(metadata.toJson()));

      final List<int> salt = codec.crypto.randomBytes(16);
      final List<int> archive = codec.encode(
        passphrase: passphrase,
        salt: salt,
        kdf: kdf,
        chunkSize: chunkSize,
        files: <Fbc1File>[
          Fbc1File('backup_meta.json', metaBytes),
          Fbc1File(storeFileName, storeBytes),
        ],
      );
      _log(LogLevel.info, 'exported');
      return BackupExportResult(
        archive: archive,
        metadata: metadata,
        fileCount: 2,
        plaintextBytes: storeBytes.length + metaBytes.length,
      );
    } finally {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    }
  }

  Future<int> _readCommitSeq(MigrationConnection source) async {
    if (!await _tableExists(source, 'commit_log')) {
      return 0;
    }
    return source.scalarInt(
      'SELECT COALESCE(MAX(commit_seq), 0) AS v FROM commit_log',
    );
  }

  Future<_StoreIdentity> _readIdentity(MigrationConnection source) async {
    if (!await _tableExists(source, 'schema_metadata')) {
      throw const BackupExportException('schema_metadata is missing.');
    }
    final List<Map<String, Object?>> rows = await source.select(
      'SELECT schema_version, generation_id FROM schema_metadata WHERE id = 1',
    );
    if (rows.isEmpty) {
      throw const BackupExportException('schema_metadata row is missing.');
    }
    final Map<String, Object?> row = rows.first;
    return _StoreIdentity(
      schemaVersion: row['schema_version']! as int,
      generationId: row['generation_id']! as String,
    );
  }

  Future<bool> _tableExists(MigrationConnection source, String name) async {
    final List<Map<String, Object?>> rows = await source.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[name],
    );
    return rows.isNotEmpty;
  }

  void _log(LogLevel level, String eventCode) {
    logger?.log(level: level, component: _component, eventCode: eventCode);
  }
}

final class _StoreIdentity {
  const _StoreIdentity({
    required this.schemaVersion,
    required this.generationId,
  });

  final int schemaVersion;
  final String generationId;
}
