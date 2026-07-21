/// The non-blocking, discoverable sync status surface (R-SYNC-005) plus the
/// authenticated-account state machine (R-SYNC-001).
///
/// Sync status is an acceleration/observability projection: it never blocks
/// local content. It exposes pending work, last success, current error,
/// open conflicts, whether a retention/epoch reset is required, and whether a
/// manual retry is available.
library;

import 'package:forge/features/sync/domain/sync_identity.dart';

/// A stable, presentation-safe classification of the current sync error, if
/// any. Mirrors the domain failure taxonomy without leaking transport details.
enum SyncErrorKind {
  none,
  network,
  authentication,
  conflict,

  /// The device's epoch is stale or its cursor expired; a bootstrap/reset is
  /// required before further push/pull.
  retentionOrEpochReset,
  server,
  unexpected,
}

/// An immutable snapshot of sync status for the UI (R-SYNC-005).
final class SyncStatus {
  const SyncStatus({
    required this.linkState,
    required this.pendingOperationCount,
    required this.openConflictCount,
    required this.error,
    this.lastSuccessAtUtcMicros,
    this.currentErrorCode,
  });

  /// The signed-out, inert status used before any account is linked.
  factory SyncStatus.signedOut() => const SyncStatus(
    linkState: SyncLinkState.signedOut,
    pendingOperationCount: 0,
    openConflictCount: 0,
    error: SyncErrorKind.none,
  );

  final SyncLinkState linkState;
  final int pendingOperationCount;
  final int openConflictCount;
  final SyncErrorKind error;

  /// Microseconds since epoch (UTC) of the last successful sync, or null.
  final int? lastSuccessAtUtcMicros;

  /// A stable, presentation-safe error code for the current error, or null.
  final String? currentErrorCode;

  bool get hasPending => pendingOperationCount > 0;

  bool get hasConflicts => openConflictCount > 0;

  /// Whether a retention/epoch reset (bootstrap) is required before sync can
  /// resume (R-SYNC-005 "retention/epoch reset").
  bool get requiresReset => error == SyncErrorKind.retentionOrEpochReset;

  /// Whether a manual retry is offered. A retry is meaningful when the account
  /// can exchange data, no reset is pending, and there is either an error to
  /// clear or pending work to flush (R-SYNC-005 "manual retry").
  bool get canRetry =>
      linkState.canExchange &&
      !requiresReset &&
      (error != SyncErrorKind.none || hasPending);

  SyncStatus copyWith({
    SyncLinkState? linkState,
    int? pendingOperationCount,
    int? openConflictCount,
    SyncErrorKind? error,
    int? lastSuccessAtUtcMicros,
    String? currentErrorCode,
  }) => SyncStatus(
    linkState: linkState ?? this.linkState,
    pendingOperationCount: pendingOperationCount ?? this.pendingOperationCount,
    openConflictCount: openConflictCount ?? this.openConflictCount,
    error: error ?? this.error,
    lastSuccessAtUtcMicros:
        lastSuccessAtUtcMicros ?? this.lastSuccessAtUtcMicros,
    currentErrorCode: currentErrorCode ?? this.currentErrorCode,
  );
}
