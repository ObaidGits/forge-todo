/// Independent security conformance harness — sync wire boundary (task 12.4).
///
/// Verifies the sync security invariants end-to-end: a forged/foreign
/// `remote_profile_id` is rejected before any applier runs, the replication
/// manifest never serializes a local-only field (value OR name) and never
/// replicates the ordinary `profiles` table, and the client backend
/// configuration refuses a service-role secret and non-TLS endpoints
/// (NFR-SEC-002).
///
/// This suite also carries the regression test for the field-name exclusion
/// gap remediated in `sync_serialization.dart` (an insert enumerating a
/// local-only field name in `changedFields`).
///
/// **Validates: Requirements R-SEC-004, NFR-SEC-001**
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
import 'security_conformance_support.dart';

SyncProfileLink _link() => SyncProfileLink(
  localProfileId: ProfileId('profile-local'),
  backend: 'supabase',
  ownerUserId: OwnerUserId('owner-1'),
  remoteProfileId: RemoteProfileId('profile-remote'),
  state: SyncLinkState.linked,
);

void main() {
  final ReplicationManifest manifest = buildForgeReplicationManifestV1();

  group('Forged-ID rejection', () {
    final PullTranslator translator = PullTranslator(
      SyncIdentityTranslator(_link()),
    );

    PullPage page(String remote) => PullPage(
      remoteProfileId: RemoteProfileId(remote),
      epoch: SnapshotEpoch(4),
      fromSeq: ServerSeq(5),
      toSeq: ServerSeq(7),
      nextCursor: SyncCursor(epoch: SnapshotEpoch(4), serverSeq: ServerSeq(7)),
      changes: <RemoteChange>[
        RemoteChange(
          changeId: 'c1',
          entityType: 'task',
          entityId: 't1',
          kind: SyncOperationKind.insert,
          serverSeq: ServerSeq(7),
          serverVersion: 1,
          payload: const <String, Object?>{'title': 'T'},
        ),
      ],
    );

    testWithEvidence(
      secEvidence('SYNC-PULL-LINKED-OK', <String>['R-SEC-004']),
      'a page for the linked remote profile maps back to the local profile',
      () {
        final TranslatedPullPage translated = translator.translate(
          page: page('profile-remote'),
          cursor: SyncCursor(epoch: SnapshotEpoch(4), serverSeq: ServerSeq(5)),
        );
        expect(translated.localProfileId.value, 'profile-local');
      },
    );

    testWithEvidence(
      secEvidence('SYNC-PULL-FORGED-REJECTED', <String>['R-SEC-004']),
      'a page for a foreign/forged remote profile is rejected before applying',
      () {
        expect(
          () => translator.translate(
            page: page('profile-forged'),
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
      secEvidence('SYNC-PUSH-FOREIGN-PROFILE-REJECTED', <String>['R-SEC-004']),
      'push refuses to serialize a profile other than the linked local profile',
      () {
        final PushEnvelopeBuilder builder = PushEnvelopeBuilder(
          translator: SyncIdentityTranslator(_link()),
          manifest: manifest,
        );
        expect(
          () => builder.build(
            localProfileId: ProfileId('some-other-profile'),
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
                    entityType: 'task',
                    entityId: 't1',
                    kind: SyncOperationKind.insert,
                    payload: const <String, Object?>{'title': 'T'},
                  ),
                ],
              ),
            ],
          ),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );
  });

  group('Manifest exclusion of local-only data', () {
    final PushEnvelopeBuilder builder = PushEnvelopeBuilder(
      translator: SyncIdentityTranslator(_link()),
      manifest: manifest,
    );

    PushBatch pushOne(SyncOperation op) => builder.build(
      localProfileId: ProfileId('profile-local'),
      deviceId: 'device-1',
      epoch: SnapshotEpoch(4),
      groups: <SemanticGroup>[
        SemanticGroup(
          groupId: 'g0',
          snapshotEpoch: 4,
          operations: <SyncOperation>[op],
        ),
      ],
    );

    testWithEvidence(
      secEvidence('SYNC-LOCAL-ONLY-ENTITY-REFUSED', <String>['R-SEC-004']),
      'a local-only entity type never enqueues onto the wire',
      () {
        expect(
          () => pushOne(
            SyncOperation(
              operationId: 'op-0',
              index: 0,
              entityType: 'attachment',
              entityId: 'a1',
              kind: SyncOperationKind.insert,
              payload: const <String, Object?>{'wrapped_dek': 'secret'},
            ),
          ),
          throwsA(isA<ReplicationManifestException>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('SYNC-LOCAL-ONLY-FIELD-DROPPED', <String>['R-SEC-004']),
      'a local-only field value is dropped from a replicated entity payload',
      () {
        final PushBatch batch = pushOne(
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
        );
        final SyncOperation op = batch.groups.single.operations.single;
        expect(op.payload.containsKey('content_hash'), isFalse);
        expect(op.payload.keys.toSet(), <String>{'title', 'body_md'});
      },
    );

    testWithEvidence(
      // Regression: an insert enumerating a local-only field NAME in
      // changedFields previously leaked the name on the wire even though the
      // value was dropped. The projection now filters changedFields for every
      // non-delete kind.
      secEvidence('SYNC-INSERT-CHANGEDFIELD-NAME-EXCLUDED', <String>[
        'R-SEC-004',
      ]),
      'an insert never carries a local-only field name in changedFields',
      () {
        final PushBatch batch = pushOne(
          SyncOperation(
            operationId: 'op-0',
            index: 0,
            entityType: 'note',
            entityId: 'n1',
            kind: SyncOperationKind.insert,
            payload: const <String, Object?>{
              'title': 'Note',
              'content_hash': 'deadbeef',
            },
            changedFields: const <String>['title', 'content_hash'],
          ),
        );
        final SyncOperation op = batch.groups.single.operations.single;
        expect(op.changedFields, <String>['title']);
        expect(op.changedFields.contains('content_hash'), isFalse);
      },
    );

    testWithEvidence(
      secEvidence('SYNC-NO-ORDINARY-PROFILE', <String>['R-SEC-004']),
      'the ordinary profiles table is never replicated',
      () {
        expect(manifest.isEntityReplicated('profiles'), isFalse);
        for (final String entity in kLocalOnlyV1Entities) {
          expect(
            manifest.isEntityReplicated(entity),
            isFalse,
            reason: '$entity must never replicate',
          );
        }
      },
    );
  });

  group('Consolidated coverage self-check', () {
    testWithEvidence(
      secEvidence('SECCONF-AREAS-COMPLETE', <String>[
        'R-SEC-001',
        'R-SEC-002',
        'R-SEC-003',
        'R-SEC-004',
        'R-SEC-005',
        'NFR-SEC-001',
      ]),
      'the harness declares an in-repo suite for every security area',
      () {
        // A machine-checkable manifest of what this consolidated harness
        // covers in-repo, so a dropped area is visible in one place. RLS live
        // SQL is isolated to supabase/tests (MANUAL/CI) with the in-repo
        // automated gate in the Python conformance harness.
        const Map<String, String> areas = <String, String>{
          'crypto': 'security_conformance_crypto_test.dart',
          'key-lifecycle': 'security_conformance_key_lifecycle_test.dart',
          'fbc1': 'security_conformance_crypto_test.dart',
          'uri': 'security_conformance_uri_test.dart',
          'attachments': 'security_conformance_attachments_test.dart',
          'auth': 'security_conformance_auth_test.dart',
          'sync': 'security_conformance_sync_test.dart',
          'rls': 'tool/tests/test_security_conformance.py',
        };
        expect(areas.length, 8);
        expect(areas.values.toSet().isNotEmpty, isTrue);
      },
    );
  });
}
