/// Link preview options and comparison (R-SYNC-001).
///
/// A preview offers create-remote when no remote profile exists, staged-merge
/// when one does, and always offers cancel. It never auto-applies.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-PREVIEW-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.5'),
  requirements: <RequirementId>[RequirementId('R-SYNC-001')],
);

ManifestDigest _digest(int count, String hash) =>
    ManifestDigest(protocolVersion: 2, entityCount: count, rootHash: hash);

void main() {
  group('LinkPreview', () {
    testWithEvidence(
      _evidence('NO-REMOTE-OFFERS-CREATE'),
      'a preview with no remote profile offers create-remote and cancel',
      () {
        final LinkPreview preview = LinkPreview.noRemoteProfile(
          localDigest: _digest(3, 'local-hash'),
        );
        expect(preview.hasRemoteProfile, isFalse);
        expect(preview.recommended, LinkAdoptionOption.createRemote);
        expect(preview.offers(LinkAdoptionOption.createRemote), isTrue);
        expect(preview.offers(LinkAdoptionOption.cancel), isTrue);
        expect(preview.offers(LinkAdoptionOption.stagedMerge), isFalse);
      },
    );

    testWithEvidence(
      _evidence('EXISTING-REMOTE-OFFERS-MERGE'),
      'a preview with an existing remote profile offers staged-merge and cancel',
      () {
        final LinkPreview preview = LinkPreview.existingRemoteProfile(
          localDigest: _digest(3, 'local-hash'),
          remoteDigest: _digest(5, 'remote-hash'),
        );
        expect(preview.hasRemoteProfile, isTrue);
        expect(preview.recommended, LinkAdoptionOption.stagedMerge);
        expect(preview.offers(LinkAdoptionOption.stagedMerge), isTrue);
        expect(preview.offers(LinkAdoptionOption.cancel), isTrue);
        expect(preview.offers(LinkAdoptionOption.createRemote), isFalse);
        expect(preview.isAlreadyConverged, isFalse);
      },
    );

    testWithEvidence(
      _evidence('IDENTICAL-DIGESTS-CONVERGED'),
      'identical local and remote digests report already-converged',
      () {
        final LinkPreview preview = LinkPreview.existingRemoteProfile(
          localDigest: _digest(4, 'same'),
          remoteDigest: _digest(4, 'same'),
        );
        expect(preview.isAlreadyConverged, isTrue);
        // Still surfaced as a staged merge, never auto-applied.
        expect(preview.recommended, LinkAdoptionOption.stagedMerge);
      },
    );

    testWithEvidence(
      _evidence('DIGEST-MISMATCH-BY-COUNT'),
      'digests with different entity counts do not match',
      () {
        expect(_digest(3, 'h').matches(_digest(4, 'h')), isFalse);
        expect(_digest(3, 'h').matches(_digest(3, 'h')), isTrue);
      },
    );
  });
}
