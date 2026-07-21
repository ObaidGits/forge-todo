/// Link adoption, staged merge, stale-epoch bootstrap, sign-out, and
/// remote-delete reauthentication (R-SYNC-001, R-SYNC-006, R-SYNC-008).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/application/bootstrap/command_quiescence_gate.dart';
import 'package:forge/features/sync/application/bootstrap/journal_replay_rebaser.dart';
import 'package:forge/features/sync/application/bootstrap/link_adoption_service.dart';
import 'package:forge/features/sync/application/bootstrap/sync_bootstrap_coordinator.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

import '../../helpers/evidence.dart';
import 'bootstrap_fakes.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-001'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-ADOPTION-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.5'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

final OwnerUserId _owner = OwnerUserId('owner-1');
const String _backend = 'supabase';

ManifestDigest _digest(int count, String hash) =>
    ManifestDigest(protocolVersion: 2, entityCount: count, rootHash: hash);

RemoteProfileSnapshot _remoteProfile({int epoch = 7, int watermark = 100}) =>
    RemoteProfileSnapshot(
      remoteProfileId: RemoteProfileId('profile-a'),
      ownerUserId: _owner,
      epoch: epoch,
      watermark: watermark,
      digest: _digest(5, 'remote'),
    );

final class _Fixture {
  _Fixture({RemoteProfileSnapshot? remoteProfile, LocalInventory? inventory})
    : gateway = FakeRemoteBootstrapGateway(remoteProfile: remoteProfile),
      linkStore = InMemorySyncProfileLinkStore(),
      auth = FakeAuthSessionController(),
      deleter = FakeRemoteProfileDeleter() {
    final SyncBootstrapCoordinator coordinator = SyncBootstrapCoordinator(
      gate: CommandQuiescenceGate(),
      inventory: FakeLocalGenerationInventory(
        inventory ?? LocalInventory(commitSeq: 1),
      ),
      stagedBuilder: FakeStagedGenerationBuilder(),
      rebaser: const JournalReplayRebaser(),
      gateway: gateway,
      verifier: FakeManifestVerifier(),
    );
    service = LinkAdoptionService(
      coordinator: coordinator,
      gateway: gateway,
      linkStore: linkStore,
      localDigest: FakeLocalManifestDigestSource(_digest(3, 'local')),
      auth: auth,
      remoteDeleter: deleter,
    );
  }

  final FakeRemoteBootstrapGateway gateway;
  final InMemorySyncProfileLinkStore linkStore;
  final FakeAuthSessionController auth;
  final FakeRemoteProfileDeleter deleter;
  late final LinkAdoptionService service;
}

void main() {
  group('LinkAdoptionService preview', () {
    testWithEvidence(
      _evidence('PREVIEW-NO-REMOTE-CREATE'),
      'preview offers create-remote when the account has no remote profile',
      () async {
        final _Fixture fx = _Fixture();
        final LinkPreview preview = await fx.service.preview(
          owner: _owner,
          localProfile: ProfileId('profile-a'),
          backend: _backend,
        );
        expect(preview.recommended, LinkAdoptionOption.createRemote);
      },
    );

    testWithEvidence(
      _evidence('PREVIEW-EXISTING-MERGE'),
      'preview offers staged-merge when the account already has a remote profile',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile());
        final LinkPreview preview = await fx.service.preview(
          owner: _owner,
          localProfile: ProfileId('profile-b'),
          backend: _backend,
        );
        expect(preview.recommended, LinkAdoptionOption.stagedMerge);
        expect(preview.hasRemoteProfile, isTrue);
      },
    );
  });

  group('LinkAdoptionService create (first-device adoption)', () {
    testWithEvidence(
      _evidence('CREATE-REMOTE-ADOPTS-LOCAL-ID'),
      'the created remote profile adopts the creating device local profile id',
      () async {
        final _Fixture fx = _Fixture();
        final SyncProfileLink link = await fx.service.createRemoteProfile(
          owner: _owner,
          localProfile: ProfileId('profile-a'),
          backend: _backend,
        );
        expect(link.remoteProfileId.value, 'profile-a');
        expect(link.state, SyncLinkState.linked);
        expect(fx.auth.linked, isTrue);
        expect(
          (await fx.linkStore.read(
            ProfileId('profile-a'),
          ))?.remoteProfileId.value,
          'profile-a',
        );
      },
    );

    testWithEvidence(
      _evidence('CREATE-REJECTED-WHEN-REMOTE-EXISTS'),
      'creating a remote profile fails when one already exists',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile());
        await expectLater(
          fx.service.createRemoteProfile(
            owner: _owner,
            localProfile: ProfileId('profile-b'),
            backend: _backend,
          ),
          throwsA(isA<LinkAdoptionException>()),
        );
      },
    );
  });

  group('LinkAdoptionService staged merge (second device)', () {
    testWithEvidence(
      _evidence(
        'MERGE-CONFIRM-LINKS-DIFFERENT-LOCAL-ID',
        requirements: <String>['R-SYNC-001', 'R-SYNC-006'],
      ),
      'a confirmed staged merge records a link keeping the device local id',
      () async {
        final _Fixture fx = _Fixture(
          remoteProfile: _remoteProfile(),
          inventory: LocalInventory(
            commitSeq: 3,
            pendingCommands: <PendingCommandRecord>[
              PendingCommandRecord(
                commandId: 'c1',
                commitSeq: 1,
                commandType: 'task.create',
                entityType: 'task',
                entityId: 'e1',
                canonicalPayload: '{}',
                originalResultCode: 'ok',
                originalPayloadVersion: 1,
              ),
            ],
          ),
        );
        final StagedMergeHandle handle = await fx.service.stageMerge(
          owner: _owner,
          localProfile: ProfileId('profile-b'),
          backend: _backend,
        );
        expect(handle.remoteProfileId.value, 'profile-a');
        final BootstrapReport report = await handle.confirm();
        expect(report.trigger, BootstrapTrigger.stagedMerge);

        final SyncProfileLink? link = await fx.linkStore.read(
          ProfileId('profile-b'),
        );
        expect(link, isNotNull);
        // Second device keeps its own local id, links to the remote profile.
        expect(link!.localProfileId.value, 'profile-b');
        expect(link.remoteProfileId.value, 'profile-a');
        expect(fx.auth.linked, isTrue);
      },
    );

    testWithEvidence(
      _evidence(
        'MERGE-CANCEL-RECORDS-NO-LINK',
        requirements: <String>['R-SYNC-001'],
      ),
      'a cancelled staged merge records no link and stays unlinked',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile());
        final StagedMergeHandle handle = await fx.service.stageMerge(
          owner: _owner,
          localProfile: ProfileId('profile-b'),
          backend: _backend,
        );
        await handle.cancel();
        expect(await fx.linkStore.read(ProfileId('profile-b')), isNull);
        expect(fx.auth.linked, isFalse);
      },
    );

    testWithEvidence(
      _evidence('MERGE-WITHOUT-REMOTE-FAILS'),
      'staging a merge fails when no remote profile exists',
      () async {
        final _Fixture fx = _Fixture();
        await expectLater(
          fx.service.stageMerge(
            owner: _owner,
            localProfile: ProfileId('profile-b'),
            backend: _backend,
          ),
          throwsA(isA<LinkAdoptionException>()),
        );
      },
    );
  });

  group('LinkAdoptionService account swap guard', () {
    testWithEvidence(
      _evidence('ACCOUNT-SWAP-ABORTS-WITHOUT-MUTATION'),
      'a profile already linked to a different account cannot preview a new link',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile());
        await fx.linkStore.save(
          SyncProfileLink(
            localProfileId: ProfileId('profile-b'),
            backend: _backend,
            ownerUserId: OwnerUserId('owner-2'),
            remoteProfileId: RemoteProfileId('profile-a'),
            state: SyncLinkState.linked,
          ),
        );
        await expectLater(
          fx.service.preview(
            owner: _owner,
            localProfile: ProfileId('profile-b'),
            backend: _backend,
          ),
          throwsA(isA<LinkAdoptionException>()),
        );
      },
    );
  });

  group('LinkAdoptionService stale-epoch bootstrap', () {
    testWithEvidence(
      _evidence(
        'STALE-EPOCH-AUTO-ACTIVATES',
        requirements: <String>['R-SYNC-006'],
      ),
      'a stale-epoch bootstrap rebases and activates immediately',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile(epoch: 9));
        await fx.linkStore.save(
          SyncProfileLink(
            localProfileId: ProfileId('profile-b'),
            backend: _backend,
            ownerUserId: _owner,
            remoteProfileId: RemoteProfileId('profile-a'),
            state: SyncLinkState.linked,
          ),
        );
        final BootstrapReport report = await fx.service.bootstrapStaleEpoch(
          localProfile: ProfileId('profile-b'),
        );
        expect(report.trigger, BootstrapTrigger.staleEpoch);
        expect(report.newEpoch, 9);
      },
    );

    testWithEvidence(
      _evidence(
        'STALE-EPOCH-REQUIRES-LINK',
        requirements: <String>['R-SYNC-006'],
      ),
      'a stale-epoch bootstrap requires an active linked profile',
      () async {
        final _Fixture fx = _Fixture(remoteProfile: _remoteProfile());
        await expectLater(
          fx.service.bootstrapStaleEpoch(localProfile: ProfileId('profile-b')),
          throwsA(isA<LinkAdoptionException>()),
        );
      },
    );
  });

  group('LinkAdoptionService sign-out and remote delete', () {
    testWithEvidence(
      _evidence('SIGN-OUT-RETAINS-LOCAL', requirements: <String>['R-SYNC-008']),
      'sign-out retains local data and marks the link signed-out',
      () async {
        final _Fixture fx = _Fixture();
        await fx.linkStore.save(
          SyncProfileLink(
            localProfileId: ProfileId('profile-b'),
            backend: _backend,
            ownerUserId: _owner,
            remoteProfileId: RemoteProfileId('profile-a'),
            state: SyncLinkState.linked,
          ),
        );
        await fx.service.signOut(
          localProfile: ProfileId('profile-b'),
          retainLocalData: true,
        );
        expect(fx.auth.signOutCalled, isTrue);
        expect(fx.auth.signOutRetainLocal, isTrue);
        // The link row is retained (never deleted) and marked signed-out.
        final SyncProfileLink? link = await fx.linkStore.read(
          ProfileId('profile-b'),
        );
        expect(link, isNotNull);
        expect(link!.state, SyncLinkState.signedOut);
      },
    );

    testWithEvidence(
      _evidence(
        'REMOTE-DELETE-REQUIRES-REAUTH',
        requirements: <String>['R-SYNC-008'],
      ),
      'remote deletion is refused without recent reauthentication',
      () async {
        final _Fixture fx = _Fixture();
        await fx.linkStore.save(
          SyncProfileLink(
            localProfileId: ProfileId('profile-b'),
            backend: _backend,
            ownerUserId: _owner,
            remoteProfileId: RemoteProfileId('profile-a'),
            state: SyncLinkState.linked,
          ),
        );
        final RemoteDeleteOutcome outcome = await fx.service
            .requestRemoteDelete(localProfile: ProfileId('profile-b'));
        expect(outcome, RemoteDeleteOutcome.reauthenticationRequired);
        expect(fx.auth.remoteDeleteReauthRequested, isTrue);
        expect(fx.deleter.deleted, isEmpty);
      },
    );

    testWithEvidence(
      _evidence(
        'REMOTE-DELETE-WITH-REAUTH-DELETES',
        requirements: <String>['R-SYNC-008'],
      ),
      'remote deletion proceeds when reauthentication is recent',
      () async {
        final _Fixture fx = _Fixture();
        fx.auth.recentReauth = true;
        await fx.linkStore.save(
          SyncProfileLink(
            localProfileId: ProfileId('profile-b'),
            backend: _backend,
            ownerUserId: _owner,
            remoteProfileId: RemoteProfileId('profile-a'),
            state: SyncLinkState.linked,
          ),
        );
        final RemoteDeleteOutcome outcome = await fx.service
            .requestRemoteDelete(localProfile: ProfileId('profile-b'));
        expect(outcome, RemoteDeleteOutcome.deleted);
        expect(fx.deleter.deleted, <String>['profile-a']);
        expect(fx.auth.linked, isFalse);
      },
    );
  });
}
