/// The replaceable transport port over which the client pushes semantic groups
/// and pulls ordered change pages (design.md §9, R-SYNC-003/R-SYNC-007).
///
/// The transport is the only component that speaks the wire protocol. It
/// carries `remote_profile_id` (never a local profile ID) as protocol
/// ownership; the server derives the authenticated owner and validates the
/// envelope's remote profile against it. Any backend that honors protocol v2 —
/// hosted Supabase, self-hosted Supabase, or a compatible future service — is a
/// valid adapter.
library;

import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// A push batch: one authenticated device's ordered semantic groups bound to a
/// single snapshot epoch (data-model.md §6 push envelope).
final class PushBatch {
  PushBatch({
    required this.remoteProfileId,
    required this.deviceId,
    required this.snapshotEpoch,
    required List<SemanticGroup> groups,
    this.protocolVersion = kSyncProtocolVersion,
  }) : groups = List<SemanticGroup>.unmodifiable(groups) {
    for (final SemanticGroup group in groups) {
      if (group.snapshotEpoch != snapshotEpoch.value) {
        throw ArgumentError.value(
          group.groupId,
          'groups',
          'Every group in a batch must share the batch snapshot epoch.',
        );
      }
    }
  }

  final int protocolVersion;
  final RemoteProfileId remoteProfileId;
  final String deviceId;
  final SnapshotEpoch snapshotEpoch;
  final List<SemanticGroup> groups;
}

/// The response to a push: a per-group result plus the server's current epoch,
/// so a stale-epoch push can be detected and force a pull/bootstrap.
final class PushResponse {
  PushResponse({
    required this.serverEpoch,
    required List<SemanticGroupResult> results,
  }) : results = List<SemanticGroupResult>.unmodifiable(results);

  final SnapshotEpoch serverEpoch;
  final List<SemanticGroupResult> results;

  /// True when the server rejected the batch because the device's epoch is
  /// behind the server's; the client must pull/bootstrap before pushing again.
  bool get staleEpoch => results.any(
    (SemanticGroupResult r) => r.outcome == SemanticGroupOutcome.staleEpoch,
  );
}

/// A contiguous, ordered page of inbound changes (data-model.md §6 pull).
///
/// The page carries the [remoteProfileId] it was fetched for so the client can
/// validate and translate it to the existing local profile before any typed
/// applier runs; a page for any other remote profile is rejected.
final class PullPage {
  PullPage({
    required this.remoteProfileId,
    required this.epoch,
    required this.fromSeq,
    required this.toSeq,
    required List<RemoteChange> changes,
    required this.nextCursor,
    this.hasMore = false,
  }) : changes = List<RemoteChange>.unmodifiable(changes);

  final RemoteProfileId remoteProfileId;
  final SnapshotEpoch epoch;
  final ServerSeq fromSeq;
  final ServerSeq toSeq;
  final List<RemoteChange> changes;

  /// The cursor to persist after this page applies; also carries the server's
  /// opaque continuation token.
  final SyncCursor nextCursor;
  final bool hasMore;
}

/// The replaceable sync transport (design.md §9).
abstract interface class SyncTransport {
  /// Pushes a batch of semantic groups and returns per-group results.
  Future<PushResponse> push(PushBatch batch);

  /// Pulls the next contiguous page at or after [cursor].
  Future<PullPage> pull(SyncCursor cursor);
}
