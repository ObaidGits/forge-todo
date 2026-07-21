/// An ordered pull cursor over a per-owner `server_seq` within a snapshot epoch
/// (R-SYNC-003, data-model.md §6).
///
/// Pages are contiguous and ordered by sequence. The client advances its cursor
/// only monotonically within an epoch; a lower or non-contiguous sequence is a
/// gap that aborts apply and requests bootstrap. An epoch increase is a server
/// generation change: the cursor resets to the new epoch and its sequence
/// restarts. Duplicate pages (a sequence at or below the cursor in the same
/// epoch) are harmless no-ops.
library;

import 'package:forge/features/sync/domain/sync_protocol.dart';

/// The outcome of validating an incoming page's `(epoch, fromSeq)` against the
/// current cursor.
enum CursorAdvanceDecision {
  /// The page continues contiguously; apply it and advance.
  apply,

  /// The page was already applied (duplicate); ignore it idempotently.
  duplicate,

  /// A gap, expired cursor, or epoch mismatch: abort apply and bootstrap.
  bootstrap,
}

/// A pull cursor value: `(epoch, serverSeq)` plus the server's opaque token.
final class SyncCursor implements Comparable<SyncCursor> {
  SyncCursor({required this.epoch, required this.serverSeq, this.opaqueToken});

  /// The starting cursor before any pull, at the genesis epoch.
  factory SyncCursor.initial() =>
      SyncCursor(epoch: SnapshotEpoch.genesis, serverSeq: ServerSeq.zero);

  final SnapshotEpoch epoch;
  final ServerSeq serverSeq;

  /// The server's opaque continuation token, when the server supplies one.
  final String? opaqueToken;

  /// Total order across cursors: first by epoch, then by server sequence.
  @override
  int compareTo(SyncCursor other) {
    final int byEpoch = epoch.compareTo(other.epoch);
    if (byEpoch != 0) {
      return byEpoch;
    }
    return serverSeq.compareTo(other.serverSeq);
  }

  /// Decides how a page spanning `(pageEpoch, fromSeq .. toSeq]` relates to this
  /// cursor. A well-formed page satisfies `fromSeq <= toSeq`.
  CursorAdvanceDecision decide({
    required SnapshotEpoch pageEpoch,
    required ServerSeq fromSeq,
    required ServerSeq toSeq,
  }) {
    if (fromSeq.value > toSeq.value) {
      throw ArgumentError('Malformed page: fromSeq exceeds toSeq.');
    }
    if (pageEpoch.value > epoch.value) {
      // A newer epoch is a server generation change: the client must bootstrap
      // to rebase onto it rather than blindly applying (data-model.md §6).
      return CursorAdvanceDecision.bootstrap;
    }
    if (pageEpoch.value < epoch.value) {
      // A page from a retired epoch is stale.
      return CursorAdvanceDecision.bootstrap;
    }
    // Same epoch: the page must begin exactly where the cursor left off.
    if (toSeq.value <= serverSeq.value) {
      return CursorAdvanceDecision.duplicate;
    }
    if (fromSeq.value != serverSeq.value) {
      // A gap (fromSeq ahead of the cursor) or overlap that does not begin at
      // the cursor is not contiguous; abort and bootstrap.
      return CursorAdvanceDecision.bootstrap;
    }
    return CursorAdvanceDecision.apply;
  }

  /// Advances the cursor to [toSeq] within the same epoch after a page applies.
  /// Never moves backward; a lower target is rejected.
  SyncCursor advanceTo(ServerSeq toSeq, {String? opaqueToken}) {
    if (toSeq.value < serverSeq.value) {
      throw ArgumentError('A cursor never moves backward within an epoch.');
    }
    return SyncCursor(
      epoch: epoch,
      serverSeq: toSeq,
      opaqueToken: opaqueToken ?? this.opaqueToken,
    );
  }

  /// Resets the cursor onto a newer [newEpoch] after a verified bootstrap,
  /// restarting the sequence at [startSeq] (default zero).
  SyncCursor resetToEpoch(SnapshotEpoch newEpoch, {ServerSeq? startSeq}) {
    if (newEpoch.value < epoch.value) {
      throw ArgumentError('Cannot reset to an older epoch.');
    }
    return SyncCursor(epoch: newEpoch, serverSeq: startSeq ?? ServerSeq.zero);
  }

  @override
  bool operator ==(Object other) =>
      other is SyncCursor &&
      other.epoch == epoch &&
      other.serverSeq == serverSeq &&
      other.opaqueToken == opaqueToken;

  @override
  int get hashCode => Object.hash(epoch, serverSeq, opaqueToken);

  @override
  String toString() =>
      'SyncCursor(epoch=${epoch.value}, seq=${serverSeq.value})';
}
