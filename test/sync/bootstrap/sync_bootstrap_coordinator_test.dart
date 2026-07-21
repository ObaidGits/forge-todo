/// Bootstrap orchestration under the exclusive maintenance gate (R-SYNC-006).
///
/// Covers command quiescence and retryable maintenance admission, preserved
/// local-only state and stable receipts, journal rebase without a receipt
/// short-circuit, atomic generation activation, staged-merge cancel that leaves
/// the live generation untouched, and abort/rollback on verification/build
/// failure that reopens admission.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/application/bootstrap/command_quiescence_gate.dart';
import 'package:forge/features/sync/application/bootstrap/journal_replay_rebaser.dart';
import 'package:forge/features/sync/application/bootstrap/sync_bootstrap_coordinator.dart';
import 'package:forge/features/sync/domain/bootstrap/bootstrap_phase.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../../helpers/evidence.dart';
import 'bootstrap_fakes.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-006'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-COORDINATOR-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.5'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

final ProfileId _profile = ProfileId('profile-b');
final RemoteProfileId _remote = RemoteProfileId('profile-a');

LocalOnlyItem _item(String id, LocalOnlyKind kind) =>
    LocalOnlyItem(kind: kind, id: id, contentHash: 'hash-$id');

ReceiptRecord _receipt(String commandId) => ReceiptRecord(
  commandId: commandId,
  requestHash: 'hash-$commandId',
  resultCode: 'ok',
  payloadVersion: 1,
  commitSeq: 1,
);

PendingCommandRecord _pending(
  String id,
  int commitSeq, {
  int? baseRowVersion,
}) => PendingCommandRecord(
  commandId: id,
  commitSeq: commitSeq,
  commandType: 'task.update',
  entityType: 'task',
  entityId: 'entity-$id',
  canonicalPayload: '{"id":"$id"}',
  originalResultCode: 'ok',
  originalPayloadVersion: 1,
  baseRowVersion: baseRowVersion,
);

RemoteChange _change(String entityId, int seq) => RemoteChange(
  changeId: 'chg-$entityId',
  entityType: 'task',
  entityId: entityId,
  kind: SyncOperationKind.patch,
  serverSeq: ServerSeq(seq),
  serverVersion: 3,
  payload: const <String, Object?>{'title': 'from-remote'},
);

SyncBootstrapCoordinator _coordinator({
  required MaintenanceGate gate,
  required LocalInventory inventory,
  required FakeStagedGenerationBuilder builder,
  List<RemoteChange> pullPage = const <RemoteChange>[],
  String? verifierFailure,
}) => SyncBootstrapCoordinator(
  gate: gate,
  inventory: FakeLocalGenerationInventory(inventory),
  stagedBuilder: builder,
  rebaser: const JournalReplayRebaser(),
  gateway: FakeRemoteBootstrapGateway(pullPage: pullPage),
  verifier: FakeManifestVerifier(failureReason: verifierFailure),
);

void main() {
  group('SyncBootstrapCoordinator', () {
    testWithEvidence(
      _evidence('PRESERVES-STATE-AND-ACTIVATES-ATOMICALLY'),
      'a bootstrap preserves local-only state and receipts, rebases the '
      'journal, pulls, and activates atomically',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        final LocalInventory inventory = LocalInventory(
          commitSeq: 42,
          localOnly: <LocalOnlyItem>[
            _item('draft-1', LocalOnlyKind.draft),
            _item('attach-1', LocalOnlyKind.attachmentMetadata),
            _item('setting-1', LocalOnlyKind.privateSetting),
          ],
          receipts: <ReceiptRecord>[
            _receipt('c1'),
            _receipt('c2'),
            _receipt('settled-1'),
          ],
          pendingCommands: <PendingCommandRecord>[
            _pending('c1', 3, baseRowVersion: null),
            _pending('c2', 5, baseRowVersion: null),
          ],
        );
        final FakeStagedGenerationBuilder builder =
            FakeStagedGenerationBuilder();
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: inventory,
          builder: builder,
          pullPage: <RemoteChange>[_change('remote-1', 1)],
        );

        final BootstrapSession session = await coordinator.begin(
          profile: _profile,
          remoteProfileId: _remote,
          serverEpoch: 7,
          watermark: 100,
          trigger: BootstrapTrigger.stagedMerge,
        );

        // Quiescence ran and admission stays closed while staged.
        expect(gate.transactionsAwaited, isTrue);
        expect(gate.workersSettled, isTrue);
        expect(gate.isAdmitting, isFalse);

        final RecordingStagedGeneration staged = builder.last;
        // All local-only items preserved.
        expect(staged.copiedLocalOnly.length, 3);
        // Every receipt preserved (settled copied + pending imported).
        expect(staged.importedReceipts.length, 3);
        // Journal rebased: two inserts against an empty base become two groups.
        expect(staged.newGroups.length, 2);
        expect(staged.conflicts, isEmpty);
        // Post-watermark pull applied.
        expect(staged.pulledChanges.length, 1);
        // Not yet activated.
        expect(staged.activated, isFalse);

        final BootstrapReport report = await session.activate();
        expect(staged.activated, isTrue);
        expect(gate.isAdmitting, isTrue);
        expect(report.newEpoch, 7);
        expect(report.newEpochGroupCount, 2);
        expect(report.localOnlyItemsPreserved, 3);
        expect(report.receiptsPreserved, 3);
      },
    );

    testWithEvidence(
      _evidence('IMPORTS-RECEIPTS-AFTER-REBASE'),
      'pending-command receipts are imported only after the journal rebases',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        // A single pending command whose receipt must be restored after its
        // intent rebases (stable receipt restoration).
        final LocalInventory inventory = LocalInventory(
          commitSeq: 5,
          receipts: <ReceiptRecord>[_receipt('c1')],
          pendingCommands: <PendingCommandRecord>[_pending('c1', 1)],
        );
        final FakeStagedGenerationBuilder builder =
            FakeStagedGenerationBuilder();
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: inventory,
          builder: builder,
        );

        await coordinator.begin(
          profile: _profile,
          remoteProfileId: _remote,
          serverEpoch: 2,
          watermark: 0,
          trigger: BootstrapTrigger.stagedMerge,
        );
        final RecordingStagedGeneration staged = builder.last;
        // The pending command's receipt is imported unchanged.
        expect(staged.importedReceipts.single.commandId, 'c1');
        expect(staged.importedReceipts.single.resultCode, 'ok');
        // And its intent produced exactly one rebase effect.
        expect(staged.newGroups.length + staged.conflicts.length, 1);
      },
    );

    testWithEvidence(
      _evidence('CLOSED-GATE-REJECTS-COMMANDS-RETRYABLY'),
      'commands admitted during a bootstrap get a retryable maintenance result',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        final FakeStagedGenerationBuilder builder =
            FakeStagedGenerationBuilder();
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: LocalInventory(commitSeq: 1),
          builder: builder,
        );
        expect(gate.admit(), isA<Success<void>>());

        final BootstrapSession session = await coordinator.begin(
          profile: _profile,
          remoteProfileId: _remote,
          serverEpoch: 1,
          watermark: 0,
          trigger: BootstrapTrigger.staleEpoch,
        );
        final Result<void> admitted = gate.admit();
        expect(admitted, isA<Failed<void>>());
        expect(admitted.failureOrNull?.code, kMaintenanceInProgressCode);
        expect(admitted.failureOrNull?.retryable, isTrue);
        expect(admitted.failureOrNull?.kind, FailureKind.maintenanceLocked);

        await session.activate();
        expect(gate.admit(), isA<Success<void>>());
      },
    );

    testWithEvidence(
      _evidence(
        'CANCEL-LEAVES-LIVE-GENERATION-UNTOUCHED',
        requirements: <String>['R-SYNC-001'],
      ),
      'a staged-merge cancel discards staging and never activates',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        final FakeStagedGenerationBuilder builder =
            FakeStagedGenerationBuilder();
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: LocalInventory(
            commitSeq: 9,
            pendingCommands: <PendingCommandRecord>[_pending('c1', 1)],
          ),
          builder: builder,
        );

        final BootstrapSession session = await coordinator.begin(
          profile: _profile,
          remoteProfileId: _remote,
          serverEpoch: 4,
          watermark: 0,
          trigger: BootstrapTrigger.stagedMerge,
        );
        await session.cancel();

        final RecordingStagedGeneration staged = builder.last;
        expect(staged.discarded, isTrue);
        expect(staged.activated, isFalse);
        expect(session.state, BootstrapSessionState.cancelled);
        expect(gate.isAdmitting, isTrue);
      },
    );

    testWithEvidence(
      _evidence('VERIFICATION-FAILURE-ABORTS-AND-REOPENS'),
      'a manifest verification failure discards staging and reopens admission',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        final FakeStagedGenerationBuilder builder =
            FakeStagedGenerationBuilder();
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: LocalInventory(commitSeq: 1),
          builder: builder,
          verifierFailure: 'root hash mismatch',
        );

        await expectLater(
          coordinator.begin(
            profile: _profile,
            remoteProfileId: _remote,
            serverEpoch: 1,
            watermark: 0,
            trigger: BootstrapTrigger.stagedMerge,
          ),
          throwsA(
            isA<BootstrapException>().having(
              (BootstrapException e) => e.phase,
              'phase',
              BootstrapPhase.verify,
            ),
          ),
        );
        expect(builder.last.discarded, isTrue);
        expect(builder.last.activated, isFalse);
        expect(gate.isAdmitting, isTrue);
      },
    );

    testWithEvidence(
      _evidence('BUILD-FAILURE-REOPENS-ADMISSION'),
      'a staging build failure reopens admission without a live switch',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        final FakeStagedGenerationBuilder builder = FakeStagedGenerationBuilder(
          failBuild: true,
        );
        final SyncBootstrapCoordinator coordinator = _coordinator(
          gate: gate,
          inventory: LocalInventory(commitSeq: 1),
          builder: builder,
        );

        await expectLater(
          coordinator.begin(
            profile: _profile,
            remoteProfileId: _remote,
            serverEpoch: 1,
            watermark: 0,
            trigger: BootstrapTrigger.stagedMerge,
          ),
          throwsA(isA<BootstrapException>()),
        );
        expect(gate.isAdmitting, isTrue);
        expect(builder.built, isEmpty);
      },
    );

    testWithEvidence(
      _evidence('PROP-REBASE-NO-DROP-NO-DUPLICATE'),
      'across random pending sets, every command produces exactly one effect '
      'and all state is preserved',
      () async {
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          final int pendingCount = rng.nextInt(6);
          final int localOnlyCount = rng.nextInt(5);
          final int settledCount = rng.nextInt(3);
          final Map<String, int> stagedBase = <String, int>{};

          final List<PendingCommandRecord> pending = <PendingCommandRecord>[];
          final List<ReceiptRecord> receipts = <ReceiptRecord>[];
          for (int i = 0; i < pendingCount; i += 1) {
            final String id = 'c$seed-$i';
            pending.add(
              _pending(
                id,
                i + 1,
                baseRowVersion: rng.nextBool() ? rng.nextInt(4) : null,
              ),
            );
            receipts.add(_receipt(id));
            if (rng.nextBool()) {
              stagedBase['task:entity-$id'] = rng.nextInt(4);
            }
          }
          for (int i = 0; i < settledCount; i += 1) {
            receipts.add(_receipt('settled-$seed-$i'));
          }
          final List<LocalOnlyItem> localOnly = <LocalOnlyItem>[
            for (int i = 0; i < localOnlyCount; i += 1)
              _item('lo-$seed-$i', LocalOnlyKind.values[i % 5]),
          ];

          final CommandQuiescenceGate gate = CommandQuiescenceGate();
          final FakeStagedGenerationBuilder builder =
              FakeStagedGenerationBuilder(baseVersions: stagedBase);
          final SyncBootstrapCoordinator coordinator = _coordinator(
            gate: gate,
            inventory: LocalInventory(
              commitSeq: 100 + seed,
              localOnly: localOnly,
              receipts: receipts,
              pendingCommands: pending,
            ),
            builder: builder,
          );

          final BootstrapSession session = await coordinator.begin(
            profile: _profile,
            remoteProfileId: _remote,
            serverEpoch: 5,
            watermark: 0,
            trigger: BootstrapTrigger.staleEpoch,
          );
          final RecordingStagedGeneration staged = builder.last;

          // Exactly one effect per pending command; none dropped/duplicated.
          expect(
            staged.newGroups.length + staged.conflicts.length,
            pendingCount,
            reason: 'effect count mismatch seed=$seed',
          );
          expect(
            session.rebaseResults.length,
            pendingCount,
            reason: 'rebase result count mismatch seed=$seed',
          );
          // No local-only item or receipt discarded.
          expect(staged.copiedLocalOnly.length, localOnlyCount);
          expect(staged.importedReceipts.length, receipts.length);

          await session.activate();
          expect(staged.activated, isTrue);
          expect(gate.isAdmitting, isTrue);
        }
      },
    );
  });
}
