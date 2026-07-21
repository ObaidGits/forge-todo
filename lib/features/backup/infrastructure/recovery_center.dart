import 'dart:io';

import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/infrastructure/staged_restore.dart';

/// Raised when a recovery-center restore cannot complete. Carries the
/// redaction-safe phase from the underlying staged restore so the UI can
/// explain the failure without leaking content.
final class RecoveryCenterException implements Exception {
  const RecoveryCenterException(this.phase, this.detail);

  final String phase;
  final String detail;

  @override
  String toString() => 'RecoveryCenterException($phase: $detail)';
}

/// Drives the full recovery center over the existing staged generation restore
/// (`R-BACKUP-003`, `R-BACKUP-004`, V1 "full recovery center").
///
/// This is an orchestration surface, not a new backup engine: it discovers
/// available recovery points on disk and hands the selected archive to the
/// existing [StagedRestoreService], inheriting its bounded authenticated
/// validation, staged-generation verification, atomic activation, and
/// automatic rollback. The live generation is never modified until the atomic
/// switch, and any failure before the switch leaves it active.
final class RecoveryCenterService implements RecoveryCenter {
  RecoveryCenterService({
    required this.stagedRestore,
    required this.recoveryDirectories,
    this.archiveExtensions = const <String>['.fbc1', '.forgebackup'],
    this.logger,
  });

  final StagedRestoreService stagedRestore;

  /// Directories scanned for recovery points, most-preferred first (e.g. the
  /// user backup directory then the automatic safety-backup root).
  final List<RecoveryDirectory> recoveryDirectories;

  final List<String> archiveExtensions;
  final StructuredLogger? logger;

  static const String _component = 'backup.recovery_center';

  /// Lists every recovery point discovered across [recoveryDirectories],
  /// newest first. This reads only file-system metadata; archive contents stay
  /// encrypted until a passphrase is supplied at restore time.
  @override
  Future<List<RecoveryPoint>> listRecoveryPoints() async {
    final List<_DiscoveredPoint> discovered = <_DiscoveredPoint>[];
    for (final RecoveryDirectory recoveryDir in recoveryDirectories) {
      final Directory dir = Directory(recoveryDir.path);
      if (!await dir.exists()) {
        continue;
      }
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File || !_isArchive(entity.path)) {
          continue;
        }
        final FileStat stat = await entity.stat();
        discovered.add(
          _DiscoveredPoint(
            point: RecoveryPoint(
              id: _fileName(entity.path),
              label: _fileName(entity.path),
              source: recoveryDir.source,
              sizeBytes: stat.size,
              capturedAtUtcMicros: stat.modified.toUtc().microsecondsSinceEpoch,
            ),
            path: entity.path,
          ),
        );
      }
    }
    discovered.sort(
      (_DiscoveredPoint a, _DiscoveredPoint b) =>
          (b.point.capturedAtUtcMicros ?? 0).compareTo(
            a.point.capturedAtUtcMicros ?? 0,
          ),
    );
    return <RecoveryPoint>[
      for (final _DiscoveredPoint p in discovered) p.point,
    ];
  }

  /// Restores the archive identified by [point] using the existing staged
  /// restore. Throws [RecoveryCenterException] on failure; the prior generation
  /// remains (or is rolled back to) active.
  @override
  Future<RecoveryRestoreOutcome> restore({
    required RecoveryPoint point,
    required List<int> passphrase,
  }) async {
    final String? path = await _resolvePath(point);
    if (path == null) {
      throw const RecoveryCenterException(
        'resolve',
        'recovery point not found',
      );
    }
    final List<int> archive = await File(path).readAsBytes();
    try {
      final RestoreResult result = await stagedRestore.restore(
        archive: archive,
        passphrase: passphrase,
      );
      logger?.log(
        level: LogLevel.info,
        component: _component,
        eventCode: 'recovered',
      );
      return RecoveryRestoreOutcome(
        recoveredCommitSeq: result.metadata.commitSeq,
        schemaVersion: result.metadata.schemaVersion,
        rolledBack: false,
      );
    } on RestoreFailure catch (failure) {
      logger?.log(
        level: LogLevel.warning,
        component: _component,
        eventCode: 'recovery_failed',
      );
      throw RecoveryCenterException(failure.phase, failure.detail);
    }
  }

  Future<String?> _resolvePath(RecoveryPoint point) async {
    for (final RecoveryDirectory recoveryDir in recoveryDirectories) {
      final Directory dir = Directory(recoveryDir.path);
      if (!await dir.exists()) {
        continue;
      }
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is File && _fileName(entity.path) == point.id) {
          return entity.path;
        }
      }
    }
    return null;
  }

  bool _isArchive(String path) {
    final String name = _fileName(path).toLowerCase();
    return archiveExtensions.any(name.endsWith);
  }

  String _fileName(String path) => path.split('/').last;
}

/// A directory scanned for recovery points and the source label its archives
/// carry.
final class RecoveryDirectory {
  const RecoveryDirectory({required this.path, required this.source});

  final String path;
  final RecoverySource source;
}

final class _DiscoveredPoint {
  const _DiscoveredPoint({required this.point, required this.path});

  final RecoveryPoint point;
  final String path;
}
