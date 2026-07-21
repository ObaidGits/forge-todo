/// Wire-boundary serialization: identity translation + manifest projection for
/// push, and identity validation + cursor classification for pull
/// (R-SYNC-001, R-SYNC-002, R-SYNC-003, design.md §8).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/forge_replication_manifest.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix, RequirementId requirement) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('TEST-SYNC-WIRE-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('9.1'),
      requirements: <RequirementId>[requirement],
    );

SyncProfileLink _link({
  String local = 'profile-b',
  String remote = 'profile-a',
}) => SyncProfileLink(
  localProfileId: ProfileId(local),
  backend: 'supabase',
  ownerUserId: OwnerUserId('owner-1'),
  remoteProfileId: RemoteProfileId(remote),
  state: SyncLinkState.linked,
);

void main() {
  final ReplicationManifest manifest = buildForgeReplicationManifestV1();

  group('PushEnvelopeBuilder', () {
    testWithEvidence(
      _evidence('TRANSLATES-AND-PROJECTS', RequirementId('R-SYNC-002')),
      'push translates local→remote identity and drops local-only fields',
      () {
        final PushEnvelopeBuilder builder = PushEnvelopeBuilder(
          translator: SyncIdentityTranslator(_link()),
          manifest: manifest,
        );
        final PushBatch batch = builder.build(
          localProfileId: ProfileId('profile-b'),
          deviceId: 'device-1',
          epoch: SnapshotEpoch(4),
          groups: <SemanticGroup>[
            SemanticGroup(
              groupId: 'g0',
              snapshotEpoch: 4,
              operations: <SyncOperation>[
                SyncOperation(
                  operationId: 'op-0',
                  index: 0,
                  entityType: 'note',
                  entityId: 'n1',
                  kind: SyncOperationKind.insert,
                  payload: const <String, Object?>{
                    'title': 'Note',
                    'body_md': 'x',
                    'content_hash': 'deadbeef',
                  },
                ),
              ],
            ),
          ],
        );
        expect(batch.remoteProfileId.value, 'profile-a');
        expect(batch.protocolVersion, kSyncProtocolVersion);
        final SyncOperation op = batch.groups.single.operations.single;
        expect(op.payload.keys.toSet(), <String>{'title', 'body_md'});
        expect(op.payload.containsKey('content_hash'), isFalse);
      },
    );

    testWithEvidence(
      _evidence('REJECTS-NON-REPLICATED', RequirementId('R-SYNC-002')),
      'push refuses to serialize a non-replicated entity type',
      () {
        final PushEnvelopeBuilder builder = PushEnvelopeBuilder(
          translator: SyncIdentityTranslator(_link()),
          manifest: manifest,
        );
        expect(
          () => builder.build(
            localProfileId: ProfileId('profile-b'),
            deviceId: 'device-1',
            epoch: SnapshotEpoch(4),
            groups: <SemanticGroup>[
              SemanticGroup(
                groupId: 'g0',
                snapshotEpoch: 4,
                operations: <SyncOperation>[
                  SyncOperation(
                    operationId: 'op-0',
                    index: 0,
                    entityType: 'note_draft',
                    entityId: 'd1',
                    kind: SyncOperationKind.insert,
                    payload: const <String, Object?>{'body': 'secret'},
                  ),
                ],
              ),
            ],
          ),
          throwsA(isA<ReplicationManifestException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('PATCH-CHANGED-FIELDS-FILTERED', RequirementId('R-SYNC-002')),
      'a patch drops local-only changed fields from both payload and field list',
      () {
        final PushEnvelopeBuilder builder = PushEnvelopeBuilder(
          translator: SyncIdentityTranslator(_link()),
          manifest: manifest,
        );
        final PushBatch batch = builder.build(
          localProfileId: ProfileId('profile-b'),
          deviceId: 'device-1',
          epoch: SnapshotEpoch(4),
          groups: <SemanticGroup>[
            SemanticGroup(
              groupId: 'g0',
              snapshotEpoch: 4,
              operations: <SyncOperation>[
                SyncOperation(
                  operationId: 'op-0',
                  index: 0,
                  entityType: 'note',
                  entityId: 'n1',
                  kind: SyncOperationKind.patch,
                  payload: const <String, Object?>{
                    'title': 'New',
                    'content_hash': 'abc',
                  },
                  changedFields: const <String>['title', 'content_hash'],
                ),
              ],
            ),
          ],
        );
        final SyncOperation op = batch.groups.single.operations.single;
        expect(op.changedFields, <String>['title']);
        expect(op.payload.keys.toSet(), <String>{'title'});
      },
    );
  });

  group('PullTranslator', () {
    PullPage page({
      required String remote,
      int epoch = 4,
      int fromSeq = 5,
      int toSeq = 7,
    }) => PullPage(
      remoteProfileId: RemoteProfileId(remote),
      epoch: SnapshotEpoch(epoch),
      fromSeq: ServerSeq(fromSeq),
      toSeq: ServerSeq(toSeq),
      nextCursor: SyncCursor(
        epoch: SnapshotEpoch(epoch),
        serverSeq: ServerSeq(toSeq),
      ),
      changes: <RemoteChange>[
        RemoteChange(
          changeId: 'c1',
          entityType: 'task',
          entityId: 't1',
          kind: SyncOperationKind.insert,
          serverSeq: ServerSeq(toSeq),
          serverVersion: 1,
          payload: const <String, Object?>{'title': 'T'},
        ),
      ],
    );

    testWithEvidence(
      _evidence('TRANSLATES-REMOTE-TO-LOCAL', RequirementId('R-SYNC-001')),
      'pull validates the remote profile and maps it to the local profile',
      () {
        final PullTranslator translator = PullTranslator(
          SyncIdentityTranslator(_link()),
        );
        final TranslatedPullPage translated = translator.translate(
          page: page(remote: 'profile-a'),
          cursor: SyncCursor(epoch: SnapshotEpoch(4), serverSeq: ServerSeq(5)),
        );
        expect(translated.localProfileId.value, 'profile-b');
        expect(translated.decision, CursorAdvanceDecision.apply);
        expect(translated.changes, hasLength(1));
      },
    );

    testWithEvidence(
      _evidence('REJECTS-FORGED-REMOTE', RequirementId('R-SYNC-001')),
      'a page for a foreign remote profile is rejected',
      () {
        final PullTranslator translator = PullTranslator(
          SyncIdentityTranslator(_link()),
        );
        expect(
          () => translator.translate(
            page: page(remote: 'profile-forged'),
            cursor: SyncCursor(
              epoch: SnapshotEpoch(4),
              serverSeq: ServerSeq(5),
            ),
          ),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('NEWER-EPOCH-BOOTSTRAPS', RequirementId('R-SYNC-003')),
      'a valid page from a newer epoch classifies as bootstrap',
      () {
        final PullTranslator translator = PullTranslator(
          SyncIdentityTranslator(_link()),
        );
        final TranslatedPullPage translated = translator.translate(
          page: page(remote: 'profile-a', epoch: 5, fromSeq: 0, toSeq: 3),
          cursor: SyncCursor(epoch: SnapshotEpoch(4), serverSeq: ServerSeq(10)),
        );
        expect(translated.decision, CursorAdvanceDecision.bootstrap);
      },
    );
  });
}
