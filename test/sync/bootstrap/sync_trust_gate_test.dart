/// The trust-model gate blocks linking until the TLS/non-E2EE disclosure is
/// acknowledged for the current version and the backend is validated
/// (R-SYNC-007, NFR-SEC-002).
///
/// Pure gate unit tests plus an end-to-end assertion through
/// [LinkAdoptionService] proving the disclosure is *present before linking*:
/// create and staged-merge both abort without mutation when the disclosure is
/// unacknowledged.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/application/bootstrap/command_quiescence_gate.dart';
import 'package:forge/features/sync/application/bootstrap/journal_replay_rebaser.dart';
import 'package:forge/features/sync/application/bootstrap/link_adoption_service.dart';
import 'package:forge/features/sync/application/bootstrap/sync_bootstrap_coordinator.dart';
import 'package:forge/features/sync/application/bootstrap/sync_trust_gate.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/sync_backend_config.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_trust_disclosure.dart';

import '../../helpers/evidence.dart';
import 'bootstrap_fakes.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-007', 'NFR-SEC-002'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-TRUST-GATE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.10'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

/// An acknowledgement store whose value is set by the test.
final class _FakeAckStore implements TrustDisclosureAcknowledgementStore {
  _FakeAckStore(this.acknowledgement);

  SyncTrustDisclosureAcknowledgement? acknowledgement;

  @override
  Future<SyncTrustDisclosureAcknowledgement?> read() async => acknowledgement;
}

final OwnerUserId _owner = OwnerUserId('owner-1');

SyncBackendConfig _hosted() => SyncBackendConfig.hosted(
  url: 'https://forge-abcdefgh.supabase.co',
  anonKey: 'anon-public-key',
);

SyncTrustGate _gate({required bool acknowledged}) => SyncTrustGate(
  backendConfig: _hosted(),
  acknowledgementStore: _FakeAckStore(
    acknowledged ? SyncTrustDisclosure.current.acknowledge() : null,
  ),
);

ManifestDigest _digest(int count, String hash) =>
    ManifestDigest(protocolVersion: 2, entityCount: count, rootHash: hash);

RemoteProfileSnapshot _remoteProfile() => RemoteProfileSnapshot(
  remoteProfileId: RemoteProfileId('profile-a'),
  ownerUserId: _owner,
  epoch: 7,
  watermark: 100,
  digest: _digest(5, 'remote'),
);

LinkAdoptionService _service({
  required SyncTrustGate gate,
  RemoteProfileSnapshot? remoteProfile,
  required InMemorySyncProfileLinkStore linkStore,
  required FakeAuthSessionController auth,
}) {
  final FakeRemoteBootstrapGateway gateway = FakeRemoteBootstrapGateway(
    remoteProfile: remoteProfile,
  );
  final SyncBootstrapCoordinator coordinator = SyncBootstrapCoordinator(
    gate: CommandQuiescenceGate(),
    inventory: FakeLocalGenerationInventory(LocalInventory(commitSeq: 1)),
    stagedBuilder: FakeStagedGenerationBuilder(),
    rebaser: const JournalReplayRebaser(),
    gateway: gateway,
    verifier: FakeManifestVerifier(),
  );
  return LinkAdoptionService(
    coordinator: coordinator,
    gateway: gateway,
    linkStore: linkStore,
    localDigest: FakeLocalManifestDigestSource(_digest(3, 'local')),
    auth: auth,
    trustGate: gate,
  );
}

void main() {
  group('SyncTrustGate', () {
    testWithEvidence(
      _evidence('ALLOWS-WHEN-ACKNOWLEDGED'),
      'the gate allows linking to the configured backend once acknowledged',
      () async {
        final SyncTrustGate gate = _gate(acknowledged: true);
        expect(await gate.isDisclosureAcknowledged, isTrue);
        await gate.assertReadyToLink(ForgeHostedBackend.backendId);
      },
    );

    testWithEvidence(
      _evidence('BLOCKS-WHEN-UNACKNOWLEDGED'),
      'the gate blocks linking until the disclosure is acknowledged',
      () async {
        final SyncTrustGate gate = _gate(acknowledged: false);
        expect(await gate.isDisclosureAcknowledged, isFalse);
        await expectLater(
          gate.assertReadyToLink(ForgeHostedBackend.backendId),
          throwsA(isA<SyncTrustGateException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('BLOCKS-STALE-ACK-VERSION'),
      'an acknowledgement for a different disclosure version does not unlock '
      'linking',
      () async {
        final SyncTrustGate gate = SyncTrustGate(
          backendConfig: _hosted(),
          acknowledgementStore: _FakeAckStore(
            const SyncTrustDisclosureAcknowledgement(disclosureVersion: 999),
          ),
        );
        expect(await gate.isDisclosureAcknowledged, isFalse);
        await expectLater(
          gate.assertReadyToLink(ForgeHostedBackend.backendId),
          throwsA(isA<SyncTrustGateException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('BLOCKS-WRONG-BACKEND'),
      'the gate refuses to link a backend other than the configured one',
      () async {
        final SyncTrustGate gate = _gate(acknowledged: true);
        await expectLater(
          gate.assertReadyToLink('some-other-backend'),
          throwsA(isA<SyncTrustGateException>()),
        );
      },
    );
  });

  group('disclosure is present before linking (LinkAdoptionService)', () {
    testWithEvidence(
      _evidence('CREATE-BLOCKED-WITHOUT-DISCLOSURE'),
      'creating a remote profile is refused until the disclosure is '
      'acknowledged, without mutating the link store',
      () async {
        final InMemorySyncProfileLinkStore linkStore =
            InMemorySyncProfileLinkStore();
        final FakeAuthSessionController auth = FakeAuthSessionController();
        final LinkAdoptionService service = _service(
          gate: _gate(acknowledged: false),
          linkStore: linkStore,
          auth: auth,
        );
        await expectLater(
          service.createRemoteProfile(
            owner: _owner,
            localProfile: ProfileId('profile-a'),
            backend: ForgeHostedBackend.backendId,
          ),
          throwsA(isA<LinkAdoptionException>()),
        );
        expect(await linkStore.read(ProfileId('profile-a')), isNull);
        expect(auth.linked, isFalse);
      },
    );

    testWithEvidence(
      _evidence('MERGE-BLOCKED-WITHOUT-DISCLOSURE'),
      'staging a merge is refused until the disclosure is acknowledged',
      () async {
        final InMemorySyncProfileLinkStore linkStore =
            InMemorySyncProfileLinkStore();
        final FakeAuthSessionController auth = FakeAuthSessionController();
        final LinkAdoptionService service = _service(
          gate: _gate(acknowledged: false),
          remoteProfile: _remoteProfile(),
          linkStore: linkStore,
          auth: auth,
        );
        await expectLater(
          service.stageMerge(
            owner: _owner,
            localProfile: ProfileId('profile-b'),
            backend: ForgeHostedBackend.backendId,
          ),
          throwsA(isA<LinkAdoptionException>()),
        );
        expect(await linkStore.read(ProfileId('profile-b')), isNull);
      },
    );

    testWithEvidence(
      _evidence('CREATE-ALLOWED-AFTER-DISCLOSURE'),
      'creating a remote profile succeeds once the disclosure is acknowledged',
      () async {
        final InMemorySyncProfileLinkStore linkStore =
            InMemorySyncProfileLinkStore();
        final FakeAuthSessionController auth = FakeAuthSessionController();
        final LinkAdoptionService service = _service(
          gate: _gate(acknowledged: true),
          linkStore: linkStore,
          auth: auth,
        );
        final SyncProfileLink link = await service.createRemoteProfile(
          owner: _owner,
          localProfile: ProfileId('profile-a'),
          backend: ForgeHostedBackend.backendId,
        );
        expect(link.state, SyncLinkState.linked);
        expect(auth.linked, isTrue);
      },
    );
  });
}
