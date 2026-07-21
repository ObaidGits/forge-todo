import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/schema_migration.dart';

import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-MIGRATE-PLAN-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.5'),
  requirements: <RequirementId>[
    RequirementId('NFR-REL-001'),
    RequirementId('NFR-REL-002'),
  ],
);

MigrationPlan _additive(int from) => MigrationPlan(
  sourceVersion: from,
  targetVersion: from + 1,
  requiresShadowGeneration: false,
  applyInPlace: (MigrationConnection _) async {},
);

MigrationPlan _incompatible(int from) => MigrationPlan(
  sourceVersion: from,
  targetVersion: from + 1,
  requiresShadowGeneration: true,
  buildTargetSchema: (MigrationConnection _) async {},
  backfillTables: const <BackfillTable>[
    BackfillTable(name: 't', orderByColumn: 'id'),
  ],
);

void main() {
  group('given MigrationPlan validation', () {
    testWithEvidence(
      _evidence('001'),
      'a non-increasing target version is rejected',
      () async {
        expect(
          () => MigrationPlan(
            sourceVersion: 3,
            targetVersion: 3,
            requiresShadowGeneration: false,
            applyInPlace: (MigrationConnection _) async {},
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('002'),
      'an incompatible plan without a target schema builder is rejected',
      () async {
        expect(
          () => MigrationPlan(
            sourceVersion: 1,
            targetVersion: 2,
            requiresShadowGeneration: true,
            backfillTables: const <BackfillTable>[
              BackfillTable(name: 't', orderByColumn: 'id'),
            ],
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('003'),
      'an incompatible plan without backfill tables is rejected',
      () async {
        expect(
          () => MigrationPlan(
            sourceVersion: 1,
            targetVersion: 2,
            requiresShadowGeneration: true,
            buildTargetSchema: (MigrationConnection _) async {},
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('004'),
      'an additive plan without an in-place action is rejected',
      () async {
        expect(
          () => MigrationPlan(
            sourceVersion: 1,
            targetVersion: 2,
            requiresShadowGeneration: false,
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  group('given MigrationRegistry chain construction', () {
    testWithEvidence(
      _evidence('005'),
      'a multi-version step plan is rejected so the chain stays auditable',
      () async {
        expect(
          () => MigrationRegistry(<MigrationPlan>[
            MigrationPlan(
              sourceVersion: 1,
              targetVersion: 3,
              requiresShadowGeneration: false,
              applyInPlace: (MigrationConnection _) async {},
            ),
          ]),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('006'),
      'a gap in the registered chain is rejected',
      () async {
        expect(
          () => MigrationRegistry(<MigrationPlan>[_additive(1), _additive(3)]),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('007'),
      'path returns empty when already at the target',
      () async {
        final MigrationRegistry registry = MigrationRegistry(<MigrationPlan>[
          _additive(1),
        ]);
        expect(registry.path(fromVersion: 2, toVersion: 2), isEmpty);
      },
    );

    testWithEvidence(
      _evidence('008'),
      'a downgrade request is rejected rather than mutating backward',
      () async {
        final MigrationRegistry registry = MigrationRegistry(<MigrationPlan>[
          _additive(1),
        ]);
        expect(
          () => registry.path(fromVersion: 2, toVersion: 1),
          throwsA(isA<MigrationPathException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('009'),
      'an unsupported baseline is rejected',
      () async {
        final MigrationRegistry registry = MigrationRegistry(<MigrationPlan>[
          _additive(1),
        ]);
        expect(
          () => registry.path(fromVersion: 5, toVersion: 6),
          throwsA(isA<MigrationPathException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('010'),
      'pathRequiresShadow reflects whether any step is incompatible',
      () async {
        final MigrationRegistry registry = MigrationRegistry(<MigrationPlan>[
          _additive(1),
          _incompatible(2),
        ]);
        expect(
          registry.pathRequiresShadow(fromVersion: 1, toVersion: 2),
          isFalse,
        );
        expect(
          registry.pathRequiresShadow(fromVersion: 1, toVersion: 3),
          isTrue,
        );
        // The full path spans both steps.
        expect(registry.path(fromVersion: 1, toVersion: 3), hasLength(2));
      },
    );

    testWithEvidence(
      _evidence('011'),
      'MigrationPathException carries a descriptive message',
      () async {
        const MigrationPathException error = MigrationPathException('boom');
        expect(error.toString(), contains('boom'));
      },
    );
  });
}
