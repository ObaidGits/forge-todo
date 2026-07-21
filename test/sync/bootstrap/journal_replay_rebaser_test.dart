/// Journal rebase without a receipt short-circuit (R-SYNC-006).
///
/// The rebaser always replays the journaled intent (it never consults the
/// receipt), so every pending command produces exactly one effect: a new-epoch
/// group when the staged base still matches the command's base, or a durable
/// conflict when it diverged. The command's original stable result is echoed
/// unchanged either way.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/application/bootstrap/journal_replay_rebaser.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';

import '../../helpers/evidence.dart';
import 'bootstrap_fakes.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-REBASE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.5'),
  requirements: <RequirementId>[RequirementId('R-SYNC-006')],
);

PendingCommandRecord _command({
  required String id,
  required String entityId,
  int? baseRowVersion,
  String resultCode = 'ok',
  int payloadVersion = 1,
}) => PendingCommandRecord(
  commandId: id,
  commitSeq: 1,
  commandType: 'task.update',
  entityType: 'task',
  entityId: entityId,
  canonicalPayload: '{"id":"$entityId"}',
  originalResultCode: resultCode,
  originalPayloadVersion: payloadVersion,
  baseRowVersion: baseRowVersion,
);

void main() {
  const JournalReplayRebaser rebaser = JournalReplayRebaser();

  group('JournalReplayRebaser', () {
    testWithEvidence(
      _evidence('EXACT-BASE-APPLIES-AS-GROUP'),
      'a patch whose staged base matches its base becomes a new-epoch group',
      () async {
        final RecordingStagedGeneration staged = RecordingStagedGeneration(
          epoch: 7,
          baseVersions: <String, int>{'task:e1': 4},
        );
        final RebaseResult result = await rebaser.rebase(
          staged,
          _command(id: 'c1', entityId: 'e1', baseRowVersion: 4),
          newEpoch: 7,
        );
        expect(result.effect, RebaseEffect.newEpochGroup);
        expect(staged.newGroups.single.epoch, 7);
        expect(staged.newGroups.single.newRowVersion, 5);
        expect(staged.conflicts, isEmpty);
      },
    );

    testWithEvidence(
      _evidence('DIVERGED-BASE-BECOMES-CONFLICT'),
      'a patch whose staged base advanced past its base becomes a conflict',
      () async {
        final RecordingStagedGeneration staged = RecordingStagedGeneration(
          epoch: 7,
          baseVersions: <String, int>{'task:e1': 9},
        );
        final RebaseResult result = await rebaser.rebase(
          staged,
          _command(id: 'c1', entityId: 'e1', baseRowVersion: 4),
          newEpoch: 7,
        );
        expect(result.effect, RebaseEffect.durableConflict);
        expect(staged.conflicts.single.entityId, 'e1');
        expect(staged.newGroups, isEmpty);
      },
    );

    testWithEvidence(
      _evidence('INSERT-OVER-EXISTING-CONFLICTS'),
      'an insert whose entity already exists on the staged base conflicts',
      () async {
        final RecordingStagedGeneration staged = RecordingStagedGeneration(
          epoch: 7,
          baseVersions: <String, int>{'task:e1': 2},
        );
        final RebaseResult result = await rebaser.rebase(
          staged,
          _command(id: 'c1', entityId: 'e1'),
          newEpoch: 7,
        );
        expect(result.effect, RebaseEffect.durableConflict);
      },
    );

    testWithEvidence(
      _evidence('PRESERVES-ORIGINAL-RESULT'),
      'the rebase echoes the command original stable result unchanged',
      () async {
        final RecordingStagedGeneration staged = RecordingStagedGeneration(
          epoch: 3,
        );
        final RebaseResult result = await rebaser.rebase(
          staged,
          _command(
            id: 'c1',
            entityId: 'fresh',
            resultCode: 'created',
            payloadVersion: 9,
          ),
          newEpoch: 3,
        );
        expect(result.effect, RebaseEffect.newEpochGroup);
        expect(result.stableResultCode, 'created');
        expect(result.stablePayloadVersion, 9);
      },
    );

    testWithEvidence(
      _evidence('PROP-EXACTLY-ONE-EFFECT-PER-COMMAND'),
      'every command yields exactly one effect and preserves its result',
      () async {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final int count = 1 + rng.nextInt(6);
          final Map<String, int> baseVersions = <String, int>{};
          final List<PendingCommandRecord> commands = <PendingCommandRecord>[];
          for (int i = 0; i < count; i += 1) {
            final String entityId = 'e${rng.nextInt(4)}';
            // Randomly seed a staged base version for some entities.
            if (rng.nextBool()) {
              baseVersions['task:$entityId'] = rng.nextInt(6);
            }
            commands.add(
              _command(
                id: 'c$seed-$i',
                entityId: entityId,
                baseRowVersion: rng.nextBool() ? rng.nextInt(6) : null,
                resultCode: 'r$i',
                payloadVersion: i,
              ),
            );
          }
          final RecordingStagedGeneration staged = RecordingStagedGeneration(
            epoch: 5,
            baseVersions: baseVersions,
          );
          final List<RebaseResult> results = <RebaseResult>[];
          for (final PendingCommandRecord command in commands) {
            results.add(await rebaser.rebase(staged, command, newEpoch: 5));
          }
          // Exactly one effect per command: total effects == command count.
          expect(results.length, commands.length, reason: 'seed=$seed');
          expect(
            staged.newGroups.length + staged.conflicts.length,
            commands.length,
            reason: 'dropped or duplicated an effect seed=$seed',
          );
          // Original results preserved for every command.
          for (int i = 0; i < commands.length; i += 1) {
            expect(results[i].stableResultCode, commands[i].originalResultCode);
            expect(
              results[i].stablePayloadVersion,
              commands[i].originalPayloadVersion,
            );
          }
        }
      },
    );
  });
}
