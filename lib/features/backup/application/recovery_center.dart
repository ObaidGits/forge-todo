/// Application-layer contracts for the full recovery center (`R-BACKUP-003`,
/// `R-BACKUP-004`, V1 "full recovery center").
///
/// The recovery center is a user-facing surface over the existing staged
/// generation restore machinery (FBC1 validate + staged-restore + atomic
/// generation activation). It does not fork that machinery; it lists available
/// recovery points and drives restore with the same atomicity guarantees.
///
/// These types are pure (no database, filesystem, or Flutter) so the surface
/// can be widget-tested with fakes.
library;

/// Where a recovery point came from, so the UI can label it honestly.
enum RecoverySource {
  /// A backup the user exported deliberately.
  userBackup('user_backup'),

  /// An automatic safety backup taken before a destructive operation such as
  /// replace-restore or an incompatible migration (`R-BACKUP-004`).
  safetyBackup('safety_backup');

  const RecoverySource(this.id);

  final String id;
}

/// One recoverable point the user can restore from. Content is never exposed
/// here — only opaque, non-secret display metadata.
final class RecoveryPoint {
  const RecoveryPoint({
    required this.id,
    required this.label,
    required this.source,
    required this.sizeBytes,
    this.capturedAtUtcMicros,
  });

  /// Stable opaque identifier (e.g. the archive file name). Not a secret.
  final String id;

  /// Human-readable label shown in the list.
  final String label;

  final RecoverySource source;
  final int sizeBytes;

  /// When the backup was taken, if known from the file system. Null when the
  /// timestamp is unavailable (metadata lives inside the encrypted archive and
  /// is only known after the passphrase is entered).
  final int? capturedAtUtcMicros;

  @override
  bool operator ==(Object other) =>
      other is RecoveryPoint &&
      other.id == id &&
      other.label == label &&
      other.source == source &&
      other.sizeBytes == sizeBytes &&
      other.capturedAtUtcMicros == capturedAtUtcMicros;

  @override
  int get hashCode =>
      Object.hash(id, label, source, sizeBytes, capturedAtUtcMicros);
}

/// Application-layer port the recovery-center surface depends on.
///
/// The infrastructure `RecoveryCenterService` implements this port; the
/// presentation depends only on this contract (plus the pure types above), so
/// it never imports backup infrastructure. The composition root binds the
/// concrete implementation (design.md §4).
abstract interface class RecoveryCenter {
  /// Lists every recovery point discovered on disk, newest first. Reads only
  /// file-system metadata; archive contents stay encrypted until restore.
  Future<List<RecoveryPoint>> listRecoveryPoints();

  /// Restores [point] using the passphrase-derived key over the existing
  /// staged generation restore. The live generation is never modified until
  /// the atomic switch; any failure leaves (or rolls back to) it active.
  Future<RecoveryRestoreOutcome> restore({
    required RecoveryPoint point,
    required List<int> passphrase,
  });
}

/// Outcome of a recovery-center restore, projected for presentation. Mirrors
/// the staged-restore result without leaking generation internals.
final class RecoveryRestoreOutcome {
  const RecoveryRestoreOutcome({
    required this.recoveredCommitSeq,
    required this.schemaVersion,
    required this.rolledBack,
  });

  final int recoveredCommitSeq;
  final int schemaVersion;

  /// True when activation failed and the prior generation was restored. A
  /// rolled-back attempt is not a data-loss event (`R-BACKUP-004`).
  final bool rolledBack;
}
