import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/disk_space_preflight.dart';

import '../../helpers/helpers.dart';
import '../../helpers/migration_harness.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-PREFLIGHT-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

void main() {
  group('given the disk-space preflight for a shadow migration', () {
    testWithEvidence(
      _evidence('001'),
      'the estimate includes source, shadow, WAL/temp, backup, and margin',
      () async {
        const DiskSpacePreflight preflight = DiskSpacePreflight(_NeverProbe());
        final DiskSpaceEstimate estimate = preflight.estimate(
          sourceBytes: 200 * 1024 * 1024,
          includeBackup: true,
        );
        expect(estimate.sourceBytes, 200 * 1024 * 1024);
        expect(
          estimate.shadowBytes,
          greaterThanOrEqualTo(estimate.sourceBytes),
        );
        expect(estimate.walTempBytes, greaterThan(0));
        expect(estimate.backupBytes, estimate.sourceBytes);
        expect(estimate.marginBytes, greaterThan(0));
        expect(
          estimate.requiredBytes,
          estimate.sourceBytes +
              estimate.shadowBytes +
              estimate.walTempBytes +
              estimate.backupBytes +
              estimate.marginBytes,
        );
      },
    );

    testWithEvidence(
      _evidence('002'),
      'backup space is excluded when no safety backup is taken',
      () async {
        const DiskSpacePreflight preflight = DiskSpacePreflight(_NeverProbe());
        final DiskSpaceEstimate withBackup = preflight.estimate(
          sourceBytes: 1024,
          includeBackup: true,
        );
        final DiskSpaceEstimate withoutBackup = preflight.estimate(
          sourceBytes: 1024,
          includeBackup: false,
        );
        expect(withBackup.backupBytes, 1024);
        expect(withoutBackup.backupBytes, 0);
        expect(withoutBackup.requiredBytes, withBackup.requiredBytes - 1024);
      },
    );

    testWithEvidence(
      _evidence('003'),
      'ensureCapacity passes when the volume has room',
      () async {
        final FakeDiskSpaceProbe probe = FakeDiskSpaceProbe(
          4 * 1024 * 1024 * 1024,
        );
        final DiskSpacePreflight preflight = DiskSpacePreflight(probe);
        final DiskSpaceEstimate estimate = await preflight.ensureCapacity(
          targetPath: '/data',
          sourceBytes: 100 * 1024 * 1024,
          includeBackup: true,
        );
        expect(estimate.requiredBytes, lessThan(probe.available));
        expect(probe.lastPath, '/data');
      },
    );

    testWithEvidence(
      _evidence('004'),
      'ensureCapacity throws before any store is touched when space is short',
      () async {
        final FakeDiskSpaceProbe probe = FakeDiskSpaceProbe(10 * 1024 * 1024);
        final DiskSpacePreflight preflight = DiskSpacePreflight(probe);
        await expectLater(
          preflight.ensureCapacity(
            targetPath: '/data',
            sourceBytes: 500 * 1024 * 1024,
            includeBackup: true,
          ),
          throwsA(
            isA<InsufficientDiskSpace>().having(
              (InsufficientDiskSpace e) => e.shortfallBytes,
              'shortfallBytes',
              greaterThan(0),
            ),
          ),
        );
      },
    );
  });
}

/// A probe that must never be consulted (pure-estimate tests).
final class _NeverProbe implements DiskSpaceProbe {
  const _NeverProbe();

  @override
  Future<int> availableBytes(String path) async {
    throw StateError('Probe should not be called for a pure estimate.');
  }
}
