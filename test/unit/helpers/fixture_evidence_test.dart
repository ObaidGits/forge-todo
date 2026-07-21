import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-REL-FIXTURE-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('2.6'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-003'),
    RequirementId('NFR-REL-004'),
  ],
);

void main() {
  testWithEvidence(
    _evidence('001'),
    'versioned fixture manifest verifies immutable fixture checksum',
    () async {
      final File manifestFile = File('test/fixtures/manifest.json');
      final FixtureManifest manifest = FixtureManifest.decode(
        await manifestFile.readAsBytes(),
      );
      final VersionedFixture fixture = await VersionedFixtureLoader(
        Directory('test/fixtures'),
      ).load(manifest.entries.single);

      expect(manifest.version, 1);
      expect(fixture.fixtureId, 'foundation_empty_v1');
      expect(fixture.fixtureFormatVersion, 1);
      expect(fixture.dataSchemaVersion, 1);
      expect(fixture.releaseTag, 'MVP');
      expect(fixture.payload['profiles'], isEmpty);
      expect(
        () => fixture.payload['profiles'] = <Object>[],
        throwsUnsupportedError,
      );
      expect(
        () => (fixture.payload['profiles']! as List<Object?>).add('mutation'),
        throwsUnsupportedError,
      );
    },
  );

  testWithEvidence(
    _evidence('002'),
    'fixture loader rejects checksum mismatch and unsafe paths',
    () async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'forge-fixture-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final File fixture = File('${temporary.path}/changed.json');
      await fixture.writeAsString('{}');
      final VersionedFixtureLoader loader = VersionedFixtureLoader(temporary);

      await expectLater(
        loader.load(
          const FixtureManifestEntry(
            path: 'changed.json',
            sha256:
                'ffcbcac4bc94c559488468ca3f60ccda360fa2ae75f821de8bd9ce0efadd38db',
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        loader.load(
          const FixtureManifestEntry(
            path: '../outside.json',
            sha256:
                'ffcbcac4bc94c559488468ca3f60ccda360fa2ae75f821de8bd9ce0efadd38db',
          ),
        ),
        throwsFormatException,
      );
    },
  );

  testWithEvidence(
    _evidence('003'),
    'evidence metadata accepts exact IDs and rejects shorthand trace edges',
    () {
      final EvidenceMetadata metadata = _evidence('004');
      expect(
        metadata.testName('deterministic behavior'),
        '[TEST-REL-FIXTURE-004][MVP][TASK-2.6]'
        '[NFR-REL-003,NFR-REL-004] deterministic behavior',
      );
      expect(() => EvidenceId('TEST-*'), throwsFormatException);
      expect(() => RequirementId('NFR-REL-003/004'), throwsFormatException);
      expect(() => SpecTaskId('2'), throwsFormatException);
      expect(
        () => EvidenceMetadata(
          evidenceId: EvidenceId('TEST-REL-FIXTURE-005'),
          releaseTag: ReleaseTag.mvp,
          taskId: SpecTaskId('2.6'),
          requirements: <RequirementId>[
            RequirementId('NFR-REL-003'),
            RequirementId('NFR-REL-003'),
          ],
        ),
        throwsArgumentError,
      );
    },
  );
}
