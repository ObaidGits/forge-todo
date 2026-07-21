/// Local↔remote identity translation for protocol-v2 (R-SYNC-001).
///
/// Covers the second-device (different local id than the remote profile id),
/// forged/foreign remote-profile rejection, account-swap non-exchangeable
/// states, and the never-serialize-another-profile guard (design.md §8,
/// data-model.md §6).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-IDENTITY-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-001')],
);

SyncProfileLink _link({
  required String local,
  required String remote,
  SyncLinkState state = SyncLinkState.linked,
}) => SyncProfileLink(
  localProfileId: ProfileId(local),
  backend: 'supabase',
  ownerUserId: OwnerUserId('owner-1'),
  remoteProfileId: RemoteProfileId(remote),
  state: state,
);

void main() {
  group('SyncIdentityTranslator', () {
    testWithEvidence(
      _evidence('CREATOR-ADOPTS-LOCAL-ID'),
      'a creating device whose remote profile adopts its local id round-trips',
      () {
        final SyncIdentityTranslator translator = SyncIdentityTranslator(
          _link(local: 'profile-a', remote: 'profile-a'),
        );
        expect(
          translator.localToRemote(ProfileId('profile-a')).value,
          'profile-a',
        );
        expect(
          translator.remoteToLocal(RemoteProfileId('profile-a')).value,
          'profile-a',
        );
      },
    );

    testWithEvidence(
      _evidence('SECOND-DEVICE-DIFFERENT-LOCAL-ID'),
      'a second device keeps a different local id and still translates by link',
      () {
        // The second device kept its own local id (profile-b) but links to the
        // account's existing remote profile (profile-a). Translation is by link,
        // not value equality.
        final SyncIdentityTranslator translator = SyncIdentityTranslator(
          _link(local: 'profile-b', remote: 'profile-a'),
        );
        expect(
          translator.localToRemote(ProfileId('profile-b')).value,
          'profile-a',
        );
        expect(
          translator.remoteToLocal(RemoteProfileId('profile-a')).value,
          'profile-b',
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-FORGED-REMOTE'),
      'an inbound reference outside the linked remote profile is rejected',
      () {
        final SyncIdentityTranslator translator = SyncIdentityTranslator(
          _link(local: 'profile-b', remote: 'profile-a'),
        );
        expect(
          () => translator.remoteToLocal(RemoteProfileId('profile-forged')),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-FOREIGN-LOCAL'),
      'a device refuses to serialize a profile that is not its linked local',
      () {
        final SyncIdentityTranslator translator = SyncIdentityTranslator(
          _link(local: 'profile-b', remote: 'profile-a'),
        );
        expect(
          () => translator.localToRemote(ProfileId('profile-other')),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('ACCOUNT-SWAP-NOT-EXCHANGEABLE'),
      'a non-linked (account-changed) state cannot translate identity',
      () {
        final SyncIdentityTranslator translator = SyncIdentityTranslator(
          _link(
            local: 'profile-b',
            remote: 'profile-a',
            state: SyncLinkState.accountChanged,
          ),
        );
        expect(
          () => translator.localToRemote(ProfileId('profile-b')),
          throwsA(isA<SyncIdentityException>()),
        );
        expect(
          () => translator.remoteToLocal(RemoteProfileId('profile-a')),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('SIGNED-OUT-INERT'),
      'signed out (no link) translation throws rather than inventing identity',
      () {
        const SyncIdentityTranslator translator = SyncIdentityTranslator(null);
        expect(
          () => translator.localToRemote(ProfileId('profile-a')),
          throwsA(isA<SyncIdentityException>()),
        );
      },
    );
  });
}
