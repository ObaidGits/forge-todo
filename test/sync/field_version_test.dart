/// Per-field version arithmetic for disjoint merge and compaction
/// (R-SYNC-004, data-model.md §6).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/field_version.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-FIELDVERSION-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.1'),
  requirements: <RequirementId>[RequirementId('R-SYNC-004')],
);

FieldVersion _fv(int v, String op) =>
    FieldVersion(version: v, lastOperationId: op);

void main() {
  group('FieldVersionMap', () {
    testWithEvidence(
      _evidence('DISJOINT-TRUE'),
      'non-overlapping field sets are disjoint',
      () {
        expect(
          FieldVersionMap.disjoint(<String>['title'], <String>['notes']),
          isTrue,
        );
      },
    );

    testWithEvidence(
      _evidence('DISJOINT-FALSE'),
      'a shared field is not disjoint',
      () {
        expect(
          FieldVersionMap.disjoint(
            <String>['title', 'notes'],
            <String>['notes'],
          ),
          isFalse,
        );
      },
    );

    testWithEvidence(
      _evidence('MERGE-DISJOINT'),
      'disjoint maps merge into the union of their fields',
      () {
        final FieldVersionMap merged =
            FieldVersionMap(<String, FieldVersion>{
              'title': _fv(3, 'op-a'),
            }).mergeDisjoint(
              FieldVersionMap(<String, FieldVersion>{'notes': _fv(1, 'op-b')}),
            );
        expect(merged.fields.toSet(), <String>{'title', 'notes'});
        expect(merged['title'], _fv(3, 'op-a'));
        expect(merged['notes'], _fv(1, 'op-b'));
      },
    );

    testWithEvidence(
      _evidence('MERGE-OVERLAP-THROWS'),
      'merging overlapping fields throws rather than silently resolving',
      () {
        expect(
          () => FieldVersionMap(<String, FieldVersion>{'title': _fv(3, 'op-a')})
              .mergeDisjoint(
                FieldVersionMap(<String, FieldVersion>{
                  'title': _fv(4, 'op-b'),
                }),
              ),
          throwsStateError,
        );
      },
    );

    testWithEvidence(
      _evidence('STALE-FIELDS'),
      'staleFields reports base fields the server has since advanced',
      () {
        final FieldVersionMap base = FieldVersionMap(<String, FieldVersion>{
          'title': _fv(3, 'op-a'),
          'notes': _fv(2, 'op-b'),
        });
        final FieldVersionMap server = FieldVersionMap(<String, FieldVersion>{
          'title': _fv(5, 'op-c'),
          'notes': _fv(2, 'op-b'),
        });
        expect(base.staleFields(server), <String>['title']);
      },
    );

    testWithEvidence(
      _evidence('STALE-FIELDS-CURRENT'),
      'a base whose fields match the server has no stale fields (accept patch)',
      () {
        final FieldVersionMap base = FieldVersionMap(<String, FieldVersion>{
          'title': _fv(3, 'op-a'),
        });
        expect(base.staleFields(base), isEmpty);
      },
    );

    testWithEvidence(
      _evidence('COMPACT-LATER-WINS'),
      'compaction keeps the latest observation per field in acceptance order',
      () {
        final FieldVersionMap compacted = FieldVersionMap.compact(
          <FieldVersionMap>[
            FieldVersionMap(<String, FieldVersion>{
              'title': _fv(1, 'op-a'),
              'notes': _fv(1, 'op-a'),
            }),
            FieldVersionMap(<String, FieldVersion>{'title': _fv(2, 'op-b')}),
          ],
        );
        expect(compacted['title'], _fv(2, 'op-b'));
        expect(compacted['notes'], _fv(1, 'op-a'));
      },
    );
  });
}
