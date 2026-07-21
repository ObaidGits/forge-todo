/// Versioned replication manifest inclusion/exclusion (R-SYNC-002).
///
/// Asserts the manifest classifies entities/fields, that projection drops
/// local-only and server-only fields before serialization, that the ordinary
/// profiles table is never replicated, and that unknown territory defaults to
/// local-only (never serialized) — data-model.md §3.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/application/forge_replication_manifest.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-MANIFEST-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-002')],
);

void main() {
  final ReplicationManifest manifest = buildForgeReplicationManifestV1();

  group('ReplicationManifest classification', () {
    testWithEvidence(
      _evidence('REPLICATED-ENTITIES'),
      'every registered V1 domain entity is replicated',
      () {
        for (final String entity in kReplicatedV1Entities) {
          expect(
            manifest.isEntityReplicated(entity),
            isTrue,
            reason: '$entity should be replicated',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('LOCAL-ONLY-ENTITIES'),
      'local-only entities are never replicated',
      () {
        for (final String entity in kLocalOnlyV1Entities) {
          expect(
            manifest.isEntityReplicated(entity),
            isFalse,
            reason: '$entity must not be replicated',
          );
          expect(
            manifest.classOf(entity, 'any_field'),
            ReplicationClass.localOnly,
          );
        }
      },
    );

    testWithEvidence(
      _evidence('NO-ORDINARY-PROFILE'),
      'the ordinary profiles table is local-only, not replicated',
      () {
        expect(manifest.isEntityReplicated('profiles'), isFalse);
        // The special metadata boundary IS replicated, but as a projection.
        expect(
          manifest.isEntityReplicated(
            ReplicationManifest.profileMetadataEntity,
          ),
          isTrue,
        );
      },
    );

    testWithEvidence(
      _evidence('UNKNOWN-DEFAULTS-LOCAL'),
      'an unknown entity defaults to local-only so it is never serialized',
      () {
        expect(
          manifest.classOf('totally_unknown_entity', '*'),
          ReplicationClass.localOnly,
        );
        expect(manifest.isEntityReplicated('totally_unknown_entity'), isFalse);
      },
    );

    testWithEvidence(
      _evidence('PER-FIELD-OVERRIDE'),
      'a per-field local-only override wins over the replicated entity default',
      () {
        expect(manifest.isEntityReplicated('note'), isTrue);
        expect(manifest.isFieldReplicated('note', 'title'), isTrue);
        expect(manifest.isFieldReplicated('note', 'content_hash'), isFalse);
        expect(
          manifest.isFieldReplicated('reminder', 'delivery_token'),
          isFalse,
        );
        expect(
          manifest.classOf('task', 'server_version'),
          ReplicationClass.serverOnly,
        );
      },
    );
  });

  group('ReplicationManifest.project (exclusion)', () {
    testWithEvidence(
      _evidence('PROJECT-DROPS-LOCAL-ONLY'),
      'projection retains replicated fields and drops local-only/server-only',
      () {
        final Map<String, Object?> projected = manifest.project('note', {
          'title': 'Hello',
          'body_md': '# Hi',
          'content_hash': 'deadbeef',
        });
        expect(projected.keys.toSet(), <String>{'title', 'body_md'});
        expect(projected.containsKey('content_hash'), isFalse);
      },
    );

    testWithEvidence(
      _evidence('PROJECT-DROPS-SERVER-ONLY'),
      'server-assigned fields never appear in a projected payload',
      () {
        final Map<String, Object?> projected = manifest.project('task', {
          'title': 'Task',
          'server_version': 42,
        });
        expect(projected.keys.toSet(), <String>{'title'});
      },
    );

    testWithEvidence(
      _evidence('PROJECT-LOCAL-ONLY-ENTITY-EMPTY'),
      'projecting a local-only entity yields nothing',
      () {
        final Map<String, Object?> projected = manifest.project('note_draft', {
          'body': 'secret draft',
          'note_id': 'n1',
        });
        expect(projected, isEmpty);
      },
    );
  });

  group('ReplicationManifest guards', () {
    testWithEvidence(
      _evidence('REJECT-PROFILES-REPLICATION'),
      'a manifest that replicates the profiles table is rejected at build',
      () {
        expect(
          () => ReplicationManifest(<ManifestEntry>[
            ManifestEntry(
              entityType: ReplicationManifest.ordinaryProfilesEntity,
              field: kManifestFieldWildcard,
              replicationClass: ReplicationClass.replicated,
              introducedVersion: 2,
            ),
          ]),
          throwsA(isA<ReplicationManifestException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-DUPLICATE-ENTRY'),
      'duplicate manifest entries for the same entity/field are rejected',
      () {
        expect(
          () => ReplicationManifest(<ManifestEntry>[
            ManifestEntry(
              entityType: 'task',
              field: 'title',
              replicationClass: ReplicationClass.replicated,
              introducedVersion: 2,
            ),
            ManifestEntry(
              entityType: 'task',
              field: 'title',
              replicationClass: ReplicationClass.localOnly,
              introducedVersion: 2,
            ),
          ]),
          throwsA(isA<ReplicationManifestException>()),
        );
      },
    );
  });
}
