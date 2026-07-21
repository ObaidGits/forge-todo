/// Remote profile-metadata projection guard (R-SYNC-001, design.md §8).
///
/// Remote profile metadata maps onto the existing local profile and can never
/// create, replace, or rekey a profiles row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/profile_metadata_projection.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/database_harness.dart';
import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-PROFILEMETA-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-001')],
);

final class _RecordingProjector implements ProfileMetadataProjector {
  final List<String> projected = <String>[];

  @override
  Future<void> project(
    TransactionSession tx, {
    required ProfileId localProfileId,
    required RemoteChange change,
  }) async {
    projected.add('${localProfileId.value}:${change.entityId}');
  }
}

TransactionSession _session() => HarnessTransactionSession(
  repositories: HarnessRepositorySet(const <Type, Object>{}),
  origin: WriteOrigin.remoteApply,
  commitSeq: 1,
);

RemoteChange _metaChange(
  String entityId, {
  String type = ReplicationManifest.profileMetadataEntity,
  bool tombstone = false,
}) => RemoteChange(
  changeId: 'c-$entityId',
  entityType: type,
  entityId: entityId,
  kind: SyncOperationKind.patch,
  serverSeq: ServerSeq(1),
  serverVersion: 1,
  payload: const <String, Object?>{'display_name': 'New Name'},
  tombstone: tombstone,
);

void main() {
  group('GuardedProfileMetadataProjector', () {
    testWithEvidence(
      _evidence('PROJECTS-ONTO-EXISTING-PROFILE'),
      'metadata for the mapped local profile is projected, not inserted',
      () async {
        final _RecordingProjector delegate = _RecordingProjector();
        final GuardedProfileMetadataProjector guarded =
            GuardedProfileMetadataProjector(delegate);
        await guarded.project(
          _session(),
          localProfileId: ProfileId('profile-a'),
          change: _metaChange('profile-a'),
        );
        expect(delegate.projected, <String>['profile-a:profile-a']);
      },
    );

    testWithEvidence(
      _evidence('REJECTS-DIFFERENT-ID'),
      'metadata targeting a different profile id is rejected (no rekey)',
      () async {
        final GuardedProfileMetadataProjector guarded =
            GuardedProfileMetadataProjector(_RecordingProjector());
        await expectLater(
          guarded.project(
            _session(),
            localProfileId: ProfileId('profile-a'),
            change: _metaChange('profile-b'),
          ),
          throwsA(isA<ProfileProjectionException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-TOMBSTONE'),
      'a profile-metadata tombstone cannot delete the local profile',
      () async {
        final GuardedProfileMetadataProjector guarded =
            GuardedProfileMetadataProjector(_RecordingProjector());
        await expectLater(
          guarded.project(
            _session(),
            localProfileId: ProfileId('profile-a'),
            change: _metaChange('profile-a', tombstone: true),
          ),
          throwsA(isA<ProfileProjectionException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-WRONG-ENTITY'),
      'only profile_metadata changes may be projected',
      () async {
        final GuardedProfileMetadataProjector guarded =
            GuardedProfileMetadataProjector(_RecordingProjector());
        await expectLater(
          guarded.project(
            _session(),
            localProfileId: ProfileId('profile-a'),
            change: _metaChange('profile-a', type: 'profiles'),
          ),
          throwsA(isA<ProfileProjectionException>()),
        );
      },
    );
  });
}
