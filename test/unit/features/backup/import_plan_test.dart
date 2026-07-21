import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/import_plan.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-IMPORT-PLAN-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.6'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-005'),
    RequirementId('R-GEN-003'),
  ],
);

/// Deterministic minter producing distinct remap targets.
final class _SeqMinter implements ImportIdMinter {
  int _next = 0;
  @override
  String mint() => 'new-${_next++}';
}

ExportDocument _doc(List<ExportTable> tables) =>
    ExportDocument(createdAtUtcMicros: 1, profileId: 'p', tables: tables);

ExportTable _tasks(List<Map<String, String?>> rows) => ExportTable(
  name: 'tasks',
  columns: const <String>['id', 'life_area_id', 'title', 'deleted_at_utc'],
  rows: rows,
);

void main() {
  const ImportPlanner planner = ImportPlanner();

  testWithEvidence(
    _evidence('ADD-NEW'),
    'a non-colliding row is planned as a straight insert',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'x',
              'deleted_at_utc': null,
            },
          ]),
        ]),
        existing: const <String, Map<String, ExistingRow>>{},
        minter: _SeqMinter(),
      );
      expect(plan.addedCount, 1);
      expect(plan.rows.single.disposition, ImportDisposition.addNew);
      expect(plan.rows.single.finalId, 't1');
      expect(plan.hasRemaps, isFalse);
    },
  );

  testWithEvidence(
    _evidence('EXACT-MATCH'),
    'a row identical to an existing live row is skipped, not duplicated',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'x',
              'deleted_at_utc': null,
            },
          ]),
        ]),
        existing: <String, Map<String, ExistingRow>>{
          'tasks': <String, ExistingRow>{
            't1': const ExistingRow(
              values: <String, String?>{
                'id': 't1',
                'life_area_id': 'a1',
                'title': 'x',
                'deleted_at_utc': null,
              },
              isTombstone: false,
            ),
          },
        },
        minter: _SeqMinter(),
      );
      expect(plan.exactMatchCount, 1);
      expect(plan.writeCount, 0);
    },
  );

  testWithEvidence(
    _evidence('COLLISION-REMAP'),
    'a row colliding with a different live row is remapped to a fresh ID',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'incoming',
              'deleted_at_utc': null,
            },
          ]),
        ]),
        existing: <String, Map<String, ExistingRow>>{
          'tasks': <String, ExistingRow>{
            't1': const ExistingRow(
              values: <String, String?>{
                'id': 't1',
                'life_area_id': 'a1',
                'title': 'existing',
                'deleted_at_utc': null,
              },
              isTombstone: false,
            ),
          },
        },
        minter: _SeqMinter(),
      );
      expect(plan.collisionRemapCount, 1);
      expect(plan.rows.single.finalId, 'new-0');
      expect(plan.remaps['t1'], 'new-0');
    },
  );

  testWithEvidence(
    _evidence('TOMBSTONE-NO-RESURRECT'),
    'a row colliding with a tombstone is remapped so the deletion cannot revive',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'incoming',
              'deleted_at_utc': null,
            },
          ]),
        ]),
        existing: <String, Map<String, ExistingRow>>{
          'tasks': <String, ExistingRow>{
            't1': const ExistingRow(
              values: <String, String?>{'id': 't1'},
              isTombstone: true,
            ),
          },
        },
        minter: _SeqMinter(),
      );
      expect(plan.tombstoneBlockedCount, 1);
      expect(
        plan.rows.single.disposition,
        ImportDisposition.remapTombstoneBlocked,
      );
      expect(plan.rows.single.finalId, isNot('t1'));
      expect(plan.remaps['t1'], 'new-0');
    },
  );

  testWithEvidence(
    _evidence('INCOMING-TOMBSTONE-SKIP'),
    'an incoming tombstone row is skipped and never resurrected',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'deleted',
              'deleted_at_utc': '123',
            },
          ]),
        ]),
        existing: const <String, Map<String, ExistingRow>>{},
        minter: _SeqMinter(),
      );
      expect(plan.incomingTombstoneSkippedCount, 1);
      expect(plan.writeCount, 0);
    },
  );

  testWithEvidence(
    _evidence('REFERENCE-REMAP'),
    'a remapped parent ID is recorded so child references can follow',
    () {
      final ImportPlan plan = planner.plan(
        document: _doc(<ExportTable>[
          ExportTable(
            name: 'life_areas',
            columns: const <String>['id', 'name', 'deleted_at_utc'],
            rows: const <Map<String, String?>>[
              <String, String?>{
                'id': 'a1',
                'name': 'incoming',
                'deleted_at_utc': null,
              },
            ],
          ),
          _tasks(const <Map<String, String?>>[
            <String, String?>{
              'id': 't1',
              'life_area_id': 'a1',
              'title': 'child',
              'deleted_at_utc': null,
            },
          ]),
        ]),
        existing: <String, Map<String, ExistingRow>>{
          'life_areas': <String, ExistingRow>{
            'a1': const ExistingRow(
              values: <String, String?>{'id': 'a1', 'name': 'existing'},
              isTombstone: false,
            ),
          },
        },
        minter: _SeqMinter(),
      );
      // a1 collides and is remapped; t1 is new. The remap for a1 is available
      // so the committer can rewrite task.life_area_id.
      expect(plan.remaps['a1'], 'new-0');
      expect(plan.addedCount, 1);
      expect(plan.collisionRemapCount, 1);
    },
  );

  testWithEvidence(
    _evidence('GEN-NO-OVERWRITE'),
    'no planned write ever reuses an existing colliding live ID (generative)',
    () {
      final Random random = Random(20260706);
      for (int trial = 0; trial < 200; trial += 1) {
        final int existingCount = random.nextInt(6);
        final Map<String, ExistingRow> localRows = <String, ExistingRow>{};
        for (int i = 0; i < existingCount; i += 1) {
          final bool tomb = random.nextBool();
          localRows['t$i'] = ExistingRow(
            values: <String, String?>{'id': 't$i', 'title': 'local-$i'},
            isTombstone: tomb,
          );
        }
        final int incomingCount = random.nextInt(6);
        final List<Map<String, String?>> rows = <Map<String, String?>>[];
        for (int i = 0; i < incomingCount; i += 1) {
          rows.add(<String, String?>{
            'id': 't$i',
            'life_area_id': 'a',
            'title': random.nextBool() ? 'local-$i' : 'incoming-$i',
            'deleted_at_utc': null,
          });
        }
        final ImportPlan plan = planner.plan(
          document: _doc(<ExportTable>[_tasks(rows)]),
          existing: <String, Map<String, ExistingRow>>{'tasks': localRows},
          minter: _SeqMinter(),
        );
        for (final ImportRowPlan rowPlan in plan.rows) {
          if (!rowPlan.writes) {
            continue;
          }
          final ExistingRow? clash = localRows[rowPlan.finalId];
          // A write must never land on an existing live row's ID.
          expect(
            clash == null || clash.isTombstone,
            isTrue,
            reason: 'trial=$trial finalId=${rowPlan.finalId}',
          );
        }
      }
    },
  );
}
