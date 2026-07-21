/// Why the runtime could not open a trustworthy active generation.
///
/// Every reason is non-destructive: Recovery Mode preserves existing ciphertext
/// and key material untouched (`R-SEC-001`). The user is offered restore/repair,
/// never a silent reset.
enum RecoveryReason {
  /// Ciphertext exists but its key could not be released.
  keyUnavailable,

  /// The active-generation pointer is present but unreadable.
  pointerCorrupt,

  /// The encrypted store could not be opened (I/O, cipher, or isolate error).
  openFailed,

  /// The store opened but failed the mandatory verification sequence.
  verificationFailed,
}

/// Minimal, content-free description of a Recovery-Mode entry.
final class RecoveryModeInfo {
  const RecoveryModeInfo({required this.reason, this.detail});

  final RecoveryReason reason;

  /// A short, redaction-safe qualifier (e.g. the first failing verification
  /// check). Never contains user content.
  final String? detail;

  @override
  String toString() =>
      'RecoveryModeInfo(${reason.name}${detail == null ? '' : ', $detail'})';
}
