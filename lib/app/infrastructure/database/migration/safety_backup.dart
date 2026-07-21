import 'dart:convert';
import 'dart:io';

/// A durable record of an old-client-compatible safety backup.
///
/// The backup is a byte-for-byte copy of the source generation at its current
/// (pre-migration) schema version, so the previously installed app can open it
/// unchanged (data-model §5.2, §5.6).
final class SafetyBackupRecord {
  const SafetyBackupRecord({
    required this.directoryPath,
    required this.schemaVersion,
    required this.createdAtUtcMicros,
    required this.fileNames,
    required this.totalBytes,
  });

  final String directoryPath;
  final int schemaVersion;
  final int createdAtUtcMicros;
  final List<String> fileNames;
  final int totalBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'directory_path': directoryPath,
    'schema_version': schemaVersion,
    'created_at_utc_micros': createdAtUtcMicros,
    'file_names': fileNames,
    'total_bytes': totalBytes,
  };
}

/// Raised when a safety backup could not be completed. The migrator treats this
/// as fatal for incompatible migrations and never proceeds without one.
final class SafetyBackupException implements Exception {
  const SafetyBackupException(this.message);

  final String message;

  @override
  String toString() => 'SafetyBackupException($message)';
}

/// Creates the mandatory pre-migration safety backup.
///
/// Every incompatible migration first produces one (data-model §5.2). The
/// backup is written to a sibling directory under [backupRoot] and finalised
/// with a manifest only after every file is flushed, so an interrupted copy is
/// never mistaken for a complete backup.
final class SafetyBackup {
  const SafetyBackup({required this.now});

  /// UTC clock, injected for deterministic tests.
  final DateTime Function() now;

  Future<SafetyBackupRecord> create({
    required Directory sourceGenerationDir,
    required Directory backupRoot,
    required int sourceSchemaVersion,
    required String label,
  }) async {
    if (!await sourceGenerationDir.exists()) {
      throw SafetyBackupException(
        'Source generation directory is missing: ${sourceGenerationDir.path}',
      );
    }
    final int stamp = now().toUtc().microsecondsSinceEpoch;
    final Directory target = Directory(
      '${backupRoot.path}/safety-v$sourceSchemaVersion-$label-$stamp',
    );
    // A partially written target from a prior crash is discarded, never reused.
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.create(recursive: true);

    final List<String> copied = <String>[];
    int totalBytes = 0;
    await for (final FileSystemEntity entity in sourceGenerationDir.list()) {
      if (entity is! File) {
        // Generation stores are flat files; skip nested dirs defensively.
        continue;
      }
      final String name = _baseName(entity.path);
      final File destination = File('${target.path}/$name');
      final List<int> bytes = await entity.readAsBytes();
      await destination.writeAsBytes(bytes, flush: true);
      copied.add(name);
      totalBytes += bytes.length;
    }
    if (copied.isEmpty) {
      await target.delete(recursive: true);
      throw SafetyBackupException(
        'Source generation had no store files to back up.',
      );
    }
    copied.sort();

    final SafetyBackupRecord record = SafetyBackupRecord(
      directoryPath: target.path,
      schemaVersion: sourceSchemaVersion,
      createdAtUtcMicros: stamp,
      fileNames: List<String>.unmodifiable(copied),
      totalBytes: totalBytes,
    );
    // The manifest is the completion sentinel: its presence means the copy
    // finished. Written last, flushed, so recovery can trust it.
    await File(
      '${target.path}/backup_manifest.json',
    ).writeAsString(jsonEncode(record.toJson()), flush: true);
    return record;
  }

  String _baseName(String path) {
    final int slash = path.lastIndexOf('/');
    return slash == -1 ? path : path.substring(slash + 1);
  }
}
