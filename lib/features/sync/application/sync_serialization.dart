/// The wire boundary that ties identity translation and the replication
/// manifest together for push and pull (R-SYNC-001, R-SYNC-002, design.md §8).
///
/// * [PushEnvelopeBuilder] translates the local `profile_id` to the wire
///   `remote_profile_id` and projects every operation payload through the
///   manifest so local-only/server-only fields never serialize.
/// * [PullTranslator] validates a page's `remote_profile_id` against the active
///   link (rejecting a forged/foreign reference), translates it back to the
///   existing local `profile_id`, and classifies the page against the cursor.
library;

import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// Builds a protocol-v2 [PushBatch] from local groups under the active link.
final class PushEnvelopeBuilder {
  const PushEnvelopeBuilder({required this.translator, required this.manifest});

  final SyncIdentityTranslator translator;
  final ReplicationManifest manifest;

  /// Serializes [groups] for [localProfileId] and [deviceId] at [epoch]. The
  /// local profile is translated to the remote profile ID; each operation's
  /// payload is projected through the manifest so only replicated fields cross
  /// the wire. An operation whose entity type is not replicated is rejected —
  /// only manifest-allowlisted entities enqueue outbox work (R-SYNC-002).
  PushBatch build({
    required ProfileId localProfileId,
    required String deviceId,
    required SnapshotEpoch epoch,
    required List<SemanticGroup> groups,
  }) {
    final RemoteProfileId remote = translator.localToRemote(localProfileId);
    final List<SemanticGroup> projected = groups
        .map((SemanticGroup group) => _projectGroup(group))
        .toList(growable: false);
    return PushBatch(
      remoteProfileId: remote,
      deviceId: deviceId,
      snapshotEpoch: epoch,
      groups: projected,
    );
  }

  SemanticGroup _projectGroup(SemanticGroup group) {
    final List<SyncOperation> operations = group.operations
        .map(_projectOperation)
        .toList(growable: false);
    return SemanticGroup(
      groupId: group.groupId,
      snapshotEpoch: group.snapshotEpoch,
      operations: operations,
    );
  }

  SyncOperation _projectOperation(SyncOperation op) {
    if (!manifest.isEntityReplicated(op.entityType)) {
      throw ReplicationManifestException(
        'Refusing to serialize a non-replicated entity type: ${op.entityType}.',
      );
    }
    if (op.kind == SyncOperationKind.delete) {
      return op;
    }
    final Map<String, Object?> projected = manifest.project(
      op.entityType,
      op.payload,
    );
    // Field-name exclusion: `changedFields` is a wire field too. Filtering it
    // through the manifest for EVERY non-delete kind (not only patches) ensures
    // a local-only field NAME never leaks on an insert whose caller listed one
    // (e.g. a note insert enumerating `content_hash`). The payload projection
    // already drops the value; this closes the metadata-name gap so nothing a
    // local-only field carries — value or name — ever crosses the wire.
    final List<String> changed = manifest.replicatedFields(
      op.entityType,
      op.changedFields,
    );
    return SyncOperation(
      operationId: op.operationId,
      index: op.index,
      entityType: op.entityType,
      entityId: op.entityId,
      kind: op.kind,
      payload: projected,
      parentEntityId: op.parentEntityId,
      baseRowVersion: op.baseRowVersion,
      baseFieldVersions: op.baseFieldVersions,
      changedFields: changed,
      clientRevision: op.clientRevision,
    );
  }
}

/// A page whose remote identity has been validated and translated to the local
/// profile, with the cursor's apply/duplicate/bootstrap decision resolved.
final class TranslatedPullPage {
  const TranslatedPullPage({
    required this.localProfileId,
    required this.decision,
    required this.changes,
    required this.page,
  });

  final ProfileId localProfileId;
  final CursorAdvanceDecision decision;
  final List<RemoteChange> changes;
  final PullPage page;
}

/// Translates and classifies an inbound [PullPage] before it is applied.
final class PullTranslator {
  const PullTranslator(this.translator);

  final SyncIdentityTranslator translator;

  /// Validates the page's remote profile against the active link, translates it
  /// to the existing local profile, and decides how the page relates to
  /// [cursor]. Throws [SyncIdentityException] for a forged/foreign remote
  /// profile reference.
  TranslatedPullPage translate({
    required PullPage page,
    required SyncCursor cursor,
  }) {
    final ProfileId local = translator.remoteToLocal(page.remoteProfileId);
    final CursorAdvanceDecision decision = cursor.decide(
      pageEpoch: page.epoch,
      fromSeq: page.fromSeq,
      toSeq: page.toSeq,
    );
    return TranslatedPullPage(
      localProfileId: local,
      decision: decision,
      changes: page.changes,
      page: page,
    );
  }
}
