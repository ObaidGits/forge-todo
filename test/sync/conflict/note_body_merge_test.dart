/// Exact-base note merge or conflict copy (R-NOTE-007, data-model.md §6
/// rule 5).
///
/// Unit examples plus a named property test asserting that a clean three-way
/// merge only happens on disjoint edits, that a hash-less base never merges,
/// and that a merged result is always reconstructable from the exact base.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/conflict/note_body_merge.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-NOTE-MERGE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.3'),
  requirements: <RequirementId>[RequirementId('R-NOTE-007')],
);

void main() {
  group('mergeNoteBody — examples', () {
    testWithEvidence(
      _evidence('NO-EXACT-BASE-IS-CONFLICT-COPY'),
      'a null (unretained) base forces a conflict copy: a hash is never enough',
      () {
        final NoteMergeResult result = mergeNoteBody(
          base: null,
          local: 'local body',
          remote: 'remote body',
        );
        expect(result.isConflictCopy, isTrue);
        expect(result.local, 'local body');
        expect(result.remote, 'remote body');
      },
    );

    testWithEvidence(
      _evidence('IDENTICAL-EDITS-MERGE'),
      'identical concurrent bodies merge to that body',
      () {
        final NoteMergeResult result = mergeNoteBody(
          base: 'a\nb\nc\n',
          local: 'a\nB\nc\n',
          remote: 'a\nB\nc\n',
        );
        expect(result.isMerged, isTrue);
        expect(result.mergedBody, 'a\nB\nc\n');
      },
    );

    testWithEvidence(
      _evidence('ONE-SIDE-CHANGED-MERGES'),
      'when only one side changed the base, that side wins cleanly',
      () {
        final NoteMergeResult onlyLocal = mergeNoteBody(
          base: 'a\nb\nc\n',
          local: 'a\nchanged\nc\n',
          remote: 'a\nb\nc\n',
        );
        expect(onlyLocal.isMerged, isTrue);
        expect(onlyLocal.mergedBody, 'a\nchanged\nc\n');

        final NoteMergeResult onlyRemote = mergeNoteBody(
          base: 'a\nb\nc\n',
          local: 'a\nb\nc\n',
          remote: 'a\nb\nCHANGED\n',
        );
        expect(onlyRemote.isMerged, isTrue);
        expect(onlyRemote.mergedBody, 'a\nb\nCHANGED\n');
      },
    );

    testWithEvidence(
      _evidence('DISJOINT-REGIONS-MERGE'),
      'edits to disjoint regions three-way merge into one body',
      () {
        // Local changes the first line; remote changes the last line.
        final NoteMergeResult result = mergeNoteBody(
          base: 'first\nmiddle\nlast\n',
          local: 'FIRST\nmiddle\nlast\n',
          remote: 'first\nmiddle\nLAST\n',
        );
        expect(result.isMerged, isTrue);
        expect(result.mergedBody, 'FIRST\nmiddle\nLAST\n');
      },
    );

    testWithEvidence(
      _evidence('OVERLAPPING-EDITS-CONFLICT-COPY'),
      'edits to the same region diverge into a conflict copy, losing neither',
      () {
        final NoteMergeResult result = mergeNoteBody(
          base: 'a\nb\nc\n',
          local: 'a\nLOCAL\nc\n',
          remote: 'a\nREMOTE\nc\n',
        );
        expect(result.isConflictCopy, isTrue);
        expect(result.base, 'a\nb\nc\n');
        expect(result.local, 'a\nLOCAL\nc\n');
        expect(result.remote, 'a\nREMOTE\nc\n');
      },
    );

    testWithEvidence(
      _evidence('DISJOINT-INSERTS-MERGE'),
      'inserts at different points merge cleanly',
      () {
        final NoteMergeResult result = mergeNoteBody(
          base: 'a\nb\nc\n',
          local: 'a\nx\nb\nc\n',
          remote: 'a\nb\nc\ny\n',
        );
        expect(result.isMerged, isTrue);
        expect(result.mergedBody, 'a\nx\nb\nc\ny\n');
      },
    );
  });

  group('mergeNoteBody — properties', () {
    testWithEvidence(
      _evidence('PROP-MERGE-VS-CONFLICT-COPY'),
      'merges only on non-overlapping edits; a merged body reduces to one side '
      'when the other is unchanged, and never silently drops content',
      () {
        for (int seed = 0; seed < 500; seed += 1) {
          final Random rng = Random(seed);
          // At least five lines so any line has a non-adjacent partner line.
          final int lineCount = 5 + rng.nextInt(4);
          final List<String> base = <String>[
            for (int i = 0; i < lineCount; i += 1) 'line$i\n',
          ];

          final List<String> local = List<String>.of(base);
          final List<String> remote = List<String>.of(base);

          final int localIdx = rng.nextInt(lineCount);
          local[localIdx] = 'LOCAL_$localIdx\n';

          // Overlap: edit the same line differently -> conflict copy.
          // Otherwise edit a NON-ADJACENT line (a common unchanged line always
          // separates the two edit regions) -> a clean three-way merge.
          final bool forceOverlap = rng.nextBool();
          final int remoteIdx;
          if (forceOverlap) {
            remoteIdx = localIdx;
          } else {
            final List<int> nonAdjacent = <int>[
              for (int j = 0; j < lineCount; j += 1)
                if ((j - localIdx).abs() >= 2) j,
            ];
            remoteIdx = nonAdjacent[rng.nextInt(nonAdjacent.length)];
          }
          remote[remoteIdx] = 'REMOTE_$remoteIdx\n';

          final String baseBody = base.join();
          final String localBody = local.join();
          final String remoteBody = remote.join();

          final NoteMergeResult result = mergeNoteBody(
            base: baseBody,
            local: localBody,
            remote: remoteBody,
          );

          if (forceOverlap) {
            // Same line changed differently: must be a conflict copy that
            // preserves both bodies.
            expect(
              result.isConflictCopy,
              isTrue,
              reason: 'expected conflict copy for seed=$seed',
            );
            expect(result.local, localBody);
            expect(result.remote, remoteBody);
          } else {
            // Non-adjacent disjoint edits: clean merge carrying both changes.
            expect(
              result.isMerged,
              isTrue,
              reason: 'expected clean merge for seed=$seed',
            );
            final String merged = result.mergedBody!;
            expect(
              merged.contains('LOCAL_$localIdx'),
              isTrue,
              reason: 'lost local edit for seed=$seed',
            );
            expect(
              merged.contains('REMOTE_$remoteIdx'),
              isTrue,
              reason: 'lost remote edit for seed=$seed',
            );
          }
        }
      },
    );

    testWithEvidence(
      _evidence('PROP-MERGE-IDENTITY-WHEN-ONE-SIDE-UNCHANGED'),
      'if one side equals the base, the merge equals the other side exactly',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final int lineCount = 1 + rng.nextInt(6);
          final List<String> base = <String>[
            for (int i = 0; i < lineCount; i += 1) 'b$i\n',
          ];
          final List<String> edited = List<String>.of(base);
          final int idx = rng.nextInt(lineCount);
          edited[idx] = 'edited$idx\n';

          final String baseBody = base.join();
          final String editedBody = edited.join();

          // Local edited, remote unchanged.
          final NoteMergeResult a = mergeNoteBody(
            base: baseBody,
            local: editedBody,
            remote: baseBody,
          );
          expect(a.isMerged, isTrue, reason: 'seed=$seed');
          expect(a.mergedBody, editedBody, reason: 'seed=$seed');

          // Remote edited, local unchanged.
          final NoteMergeResult b = mergeNoteBody(
            base: baseBody,
            local: baseBody,
            remote: editedBody,
          );
          expect(b.isMerged, isTrue, reason: 'seed=$seed');
          expect(b.mergedBody, editedBody, reason: 'seed=$seed');
        }
      },
    );
  });
}
