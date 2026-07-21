/// Fitness replication-manifest classification (task 12.1).
///
/// Asserts every fitness record type is joined to replication with the correct
/// per-field classification: the ENTERED value/unit are replicated while the
/// derived canonical `*_scaled` amounts and the local soft-delete marker stay
/// device-local, and water EVENTS replicate as ordinary fitness records (only
/// the disabled-by-default enable preference is device-local, R-FIT-003).
///
/// **Validates: Requirements R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/application/forge_replication_manifest.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-FITNESS-MANIFEST-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.1'),
  requirements: <RequirementId>[
    RequirementId('R-FIT-001'),
    RequirementId('R-FIT-002'),
    RequirementId('R-FIT-003'),
    RequirementId('R-SYNC-002'),
  ],
);

const List<String> _fitnessEntities = <String>[
  'workout_template',
  'template_exercise',
  'workout_session',
  'exercise_log',
  'set_log',
  'body_measurement',
  'water_event',
];

void main() {
  final ReplicationManifest manifest = buildForgeReplicationManifestV1();

  group('fitness records are joined to replication', () {
    testWithEvidence(
      _evidence('ENTITIES-REPLICATED'),
      'every fitness record type is replicated and registered in the manifest',
      () {
        for (final String entity in _fitnessEntities) {
          expect(
            kReplicatedV1Entities.contains(entity),
            isTrue,
            reason: '$entity must be in the client manifest allowlist',
          );
          expect(
            manifest.isEntityReplicated(entity),
            isTrue,
            reason: '$entity should be replicated',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('WATER-EVENT-REPLICATES'),
      'water events replicate as ordinary fitness records (R-FIT-003)',
      () {
        // The row itself replicates; the enable preference is device-local
        // (settings_device_private), which is a separate local-only entity.
        expect(manifest.isEntityReplicated('water_event'), isTrue);
        expect(
          manifest.isFieldReplicated('water_event', 'entered_value'),
          isTrue,
        );
        expect(
          manifest.isFieldReplicated('water_event', 'entered_unit'),
          isTrue,
        );
        expect(
          manifest.isEntityReplicated('settings_device_private'),
          isFalse,
          reason: 'the device-local water-tracking preference never replicates',
        );
      },
    );
  });

  group('unit preservation: entered fields replicate, derived stay local', () {
    testWithEvidence(
      _evidence('ENTERED-UNIT-PRESERVED'),
      'entered value/unit fields cross the wire for every measured record',
      () {
        expect(manifest.isFieldReplicated('set_log', 'weight_entered'), isTrue);
        expect(manifest.isFieldReplicated('set_log', 'weight_unit'), isTrue);
        expect(
          manifest.isFieldReplicated('set_log', 'distance_entered'),
          isTrue,
        );
        expect(manifest.isFieldReplicated('set_log', 'distance_unit'), isTrue);
        expect(
          manifest.isFieldReplicated('body_measurement', 'entered_value'),
          isTrue,
        );
        expect(
          manifest.isFieldReplicated('body_measurement', 'entered_unit'),
          isTrue,
        );
      },
    );

    testWithEvidence(
      _evidence('DERIVED-SCALED-LOCAL-ONLY'),
      'derived canonical *_scaled amounts are local-only and never serialized',
      () {
        expect(
          manifest.classOf('set_log', 'weight_scaled'),
          ReplicationClass.localOnly,
        );
        expect(
          manifest.classOf('set_log', 'distance_scaled'),
          ReplicationClass.localOnly,
        );
        expect(
          manifest.classOf('body_measurement', 'value_scaled'),
          ReplicationClass.localOnly,
        );
        expect(
          manifest.classOf('water_event', 'amount_scaled'),
          ReplicationClass.localOnly,
        );
      },
    );

    testWithEvidence(
      _evidence('SOFT-DELETE-MARKER-LOCAL-ONLY'),
      'the local soft-delete marker is device-local (delete is a tombstone op)',
      () {
        for (final String entity in <String>[
          'workout_template',
          'workout_session',
          'body_measurement',
          'water_event',
        ]) {
          expect(
            manifest.classOf(entity, 'deleted_at_utc'),
            ReplicationClass.localOnly,
            reason: '$entity.deleted_at_utc must not replicate',
          );
        }
      },
    );

    testWithEvidence(
      _evidence('PROJECT-DROPS-DERIVED'),
      'projecting a set-log payload keeps entered units and drops scaled amounts',
      () {
        final Map<String, Object?> projected = manifest.project('set_log', {
          'id': 's1',
          'exercise_log_id': 'e1',
          'rank': 'm',
          'weight_entered': 135.0,
          'weight_unit': 'lb',
          'weight_scaled': 61234567,
          'distance_scaled': 1000,
        });
        expect(projected.containsKey('weight_entered'), isTrue);
        expect(projected.containsKey('weight_unit'), isTrue);
        expect(projected.containsKey('weight_scaled'), isFalse);
        expect(projected.containsKey('distance_scaled'), isFalse);
      },
    );
  });
}
