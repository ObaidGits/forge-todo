/// Probes free space on the volume backing a path.
///
/// Concrete implementations use `statvfs`/`GetDiskFreeSpaceEx` behind the
/// platform boundary; tests inject a deterministic probe.
abstract interface class DiskSpaceProbe {
  Future<int> availableBytes(String path);
}

/// A itemised estimate of the space a shadow-generation migration needs.
///
/// The preflight includes source, shadow, WAL/temp, backup and margin
/// (data-model §5.4). Every component is reported so diagnostics can explain a
/// rejection without guessing.
final class DiskSpaceEstimate {
  const DiskSpaceEstimate({
    required this.sourceBytes,
    required this.shadowBytes,
    required this.walTempBytes,
    required this.backupBytes,
    required this.marginBytes,
  });

  final int sourceBytes;
  final int shadowBytes;
  final int walTempBytes;
  final int backupBytes;
  final int marginBytes;

  int get requiredBytes =>
      sourceBytes + shadowBytes + walTempBytes + backupBytes + marginBytes;

  @override
  String toString() =>
      'DiskSpaceEstimate(required=$requiredBytes, source=$sourceBytes, '
      'shadow=$shadowBytes, walTemp=$walTempBytes, backup=$backupBytes, '
      'margin=$marginBytes)';
}

/// Tunable multipliers/floors for the estimate. Defaults are conservative.
final class DiskSpacePolicy {
  const DiskSpacePolicy({
    this.shadowFactor = 1.25,
    this.walTempFactor = 0.5,
    this.minWalTempBytes = 16 * 1024 * 1024,
    this.marginFactor = 0.1,
    this.minMarginBytes = 32 * 1024 * 1024,
  }) : assert(shadowFactor >= 1.0, 'Shadow cannot be smaller than source.'),
       assert(walTempFactor >= 0, 'WAL/temp factor must be nonnegative.'),
       assert(marginFactor >= 0, 'Margin factor must be nonnegative.');

  /// Shadow store is at least this multiple of the source (rebuild overhead).
  final double shadowFactor;

  /// WAL/temp headroom as a fraction of source size, with a floor.
  final double walTempFactor;
  final int minWalTempBytes;

  /// Safety margin as a fraction of source size, with a floor.
  final double marginFactor;
  final int minMarginBytes;
}

/// Raised when the volume cannot hold the migration. The migrator surfaces it
/// before touching any store, so the prior generation stays live and intact.
final class InsufficientDiskSpace implements Exception {
  const InsufficientDiskSpace({
    required this.availableBytes,
    required this.estimate,
  });

  final int availableBytes;
  final DiskSpaceEstimate estimate;

  int get shortfallBytes => estimate.requiredBytes - availableBytes;

  @override
  String toString() =>
      'InsufficientDiskSpace(available=$availableBytes, need=$estimate, '
      'shortfall=$shortfallBytes)';
}

/// Computes and enforces the pre-migration disk-space budget.
final class DiskSpacePreflight {
  const DiskSpacePreflight(this.probe, {this.policy = const DiskSpacePolicy()});

  final DiskSpaceProbe probe;
  final DiskSpacePolicy policy;

  DiskSpaceEstimate estimate({
    required int sourceBytes,
    required bool includeBackup,
  }) {
    if (sourceBytes < 0) {
      throw ArgumentError.value(sourceBytes, 'sourceBytes', 'Must be >= 0.');
    }
    final int shadow = (sourceBytes * policy.shadowFactor).ceil();
    final int walTemp = _atLeast(
      (sourceBytes * policy.walTempFactor).ceil(),
      policy.minWalTempBytes,
    );
    final int backup = includeBackup ? sourceBytes : 0;
    final int margin = _atLeast(
      (sourceBytes * policy.marginFactor).ceil(),
      policy.minMarginBytes,
    );
    return DiskSpaceEstimate(
      sourceBytes: sourceBytes,
      shadowBytes: shadow,
      walTempBytes: walTemp,
      backupBytes: backup,
      marginBytes: margin,
    );
  }

  /// Throws [InsufficientDiskSpace] when [targetPath]'s volume cannot hold the
  /// estimate; otherwise returns the estimate for logging.
  Future<DiskSpaceEstimate> ensureCapacity({
    required String targetPath,
    required int sourceBytes,
    required bool includeBackup,
  }) async {
    final DiskSpaceEstimate need = estimate(
      sourceBytes: sourceBytes,
      includeBackup: includeBackup,
    );
    final int available = await probe.availableBytes(targetPath);
    if (available < need.requiredBytes) {
      throw InsufficientDiskSpace(availableBytes: available, estimate: need);
    }
    return need;
  }

  int _atLeast(int value, int floor) => value < floor ? floor : value;
}
