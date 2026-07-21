/// Crash-boundary bootstrap: a failure injected at *every* bootstrap phase
/// preserves the live generation and never leaves command admission wedged
/// (R-SYNC-006, NFR-REL-002, NFR-REL-004; data-model.md §6, testing.md §4
/// "bootstrap preservation at every crash boundary").
///
/// The [SyncBootstrapCoordinator] runs the normative pre-activation phases under
/// the exclusive maintenance gate; [BootstrapSession.activate] performs the
/// atomic generation switch. This suite injects a deterministic failure at each
/// phase in turn and asserts the same invariants every time:
///
///   * a [BootstrapException] surfaces, tagged with the phase that failed;
///   * any staged generation that was built is discarded (never activated), so
///     the prior live generation is untouched (old-or-new, never partial);
///   * command admission is reopened, so the app is not wedged in maintenance.
///
/// The existing coordinator suite covers the verify- and build-failure paths;
/// this suite is the exhaustive per-phase crash boundary that testing.md
/// requires, including the atomic-activation crash boundary.
library;

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
import 'package:forge/features/sync/domain/sync_identity.dart';

import '../../helpers/evidence.dart';
import 'bootstrap_fakes.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-006', 'NFR-REL-002'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-CRASH-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.9'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

final ProfileId _profile = ProfileId('profile-b');
final RemoteProfileId _remote = RemoteProfileId('profile-a');

// ---------------------------------------------------------------------------
// Deterministic crash fakes. Each is a normal in-memory port until told to
// crash at a specific seam; then it throws instead of performing the effect.
// ---------------------------------------------------------------------------

/// A maintenance gate that behaves like [CommandQuiescenceGate] but can throw
/// at any one of the three gate phases, while always tracking admission.
final class _CrashGate implements MaintenanceGate {
  _CrashGate({this.throwOn});

  final BootstrapPhase? throwOn;
  bool _admitting = true;
  int reopenCount = 0;
  bool transactionsAwaited = false;
  bool workersSettled = false;

  @override
  bool get isAdmitting => _admitting;

  @override
  Result<void> admit() => _admitting
      ? const Success<void>(null)
      : const Failed<void>(
          Failure(
            kind: FailureKind.maintenanceLocked,
            code: kMaintenanceInProgressCode,
            safeMessageKey: 'error.sync.maintenance_in_progress',
            retryable: true,
          ),
        );

  @override
  Future<void> closeAdmission() async {
    _admitting = false;
    _maybe(BootstrapPhase.closeAdmission);
  }

  @override
  Future<void> awaitActiveTransactions() async {
    _maybe(BootstrapPhase.awaitActiveTransactions);
    transactionsAwaited = true;
  }

  @override
  Future<void> settleSyncWorkers() async {
    _maybe(BootstrapPhase.settleSyncWorkers);
    workersSettled = true;
  }

  @override
  Future<void> reopenAdmission() async {
    reopenCount += 1;
    _admitting = true;
  }

  void _maybe(BootstrapPhase phase) {
    if (throwOn == phase) {
      throw StateError('injected crash at ${phase.name}');
    }
  }
}

/// The staged-generation seams that can crash.
enum _CrashPoint { copyLocalOnly, importReceipt, applyPulledChange, activate }

/// An in-memory staged generation that records effects and can crash at one
/// seam. Enough of [StagedGeneration] to drive the real rebaser and coordinator.
final class _CrashStagedGeneration implements StagedGeneration {
  _CrashStagedGeneration({
    required this.epoch,
    this.crashOn,
    Map<String, int> baseVersions = const <String, int>{},
  }) : _base = Map<String, int>.of(baseVersions);

  @override
  final int epoch;
  final _CrashPoint? crashOn;
  final Map<String, int> _base;

  bool activated = false;
  bool discarded = false;
  int copiedLocalOnly = 0;
  int importedReceipts = 0;
  int pulled = 0;
  int groups = 0;
  int conflicts = 0;

  @override
  Future<int?> stagedVersionOf(String entityType, String entityId) async =>
      _base['$entityType:$entityId'];

  @override
  Future<void> copyLocalOnly(LocalOnlyItem item) async {
    if (crashOn == _CrashPoint.copyLocalOnly) {
      throw StateError('injected crash at copyLocalOnly');
    }
    copiedLocalOnly += 1;
  }

  @override
  Future<void> importReceipt(ReceiptRecord receipt) async {
    if (crashOn == _CrashPoint.importReceipt) {
      throw StateError('injected crash at importReceipt');
    }
    importedReceipts += 1;
  }

  @override
  Future<void> recordNewEpochGroup(StagedGroupDraft group) async {
    groups += 1;
    _base['${group.entityType}:${group.entityId}'] = group.newRowVersion;
  }

  @override
  Future<void> recordDurableConflict(StagedConflictDraft conflict) async {
    conflicts += 1;
  }

  @override
  Future<void> applyPulledChange(RemoteChange change) async {
    if (crashOn == _CrashPoint.applyPulledChange) {
      throw StateError('injected crash at applyPulledChange');
    }
    pulled += 1;
    _base['${change.entityType}:${change.entityId}'] = change.serverVersion;
  }

  @override
  Future<void> activate() async {
    if (crashOn == _CrashPoint.activate) {
      throw StateError('injected crash at activate');
    }
    if (discarded) {
      throw StateError('cannot activate a discarded staged generation');
    }
    activated = true;
  }

  @override
  Future<void> discard() async {
    discarded = true;
  }
}

final class _CrashStagedGenerationBuilder implements StagedGenerationBuilder {
  _CrashStagedGenerationBuilder({this.crashOn, this.failBuild = false});

  final _CrashPoint? crashOn;
  final bool failBuild;
  final List<_CrashStagedGeneration> built = <_CrashStagedGeneration>[];

  _CrashStagedGeneration? get lastOrNull => built.isEmpty ? null : built.last;

  @override
  Future<StagedGeneration> build({
    required ProfileId profile,
    required int baseEpoch,
    required int watermark,
  }) async {
    if (failBuild) {
      throw StateError('injected crash at buildStaging');
    }
    final _CrashStagedGeneration staged = _CrashStagedGeneration(
      epoch: baseEpoch,
      crashOn: crashOn,
    );
    built.add(staged);
    return staged;
  }
}

final class _ThrowingInventory implements LocalGenerationInventory {
  @override
  Future<LocalInventory> inventory(ProfileId profile) async =>
      throw StateError('injected crash at inventory');
}

final class _ThrowingRebaser implements PendingCommandRebaser {
  @override
  Future<RebaseResult> rebase(
    StagedGeneration staged,
    PendingCommandRecord command, {
    required int newEpoch,
  }) async => throw StateError('injected crash at rebaseJournal');
}

final class _ThrowingGateway implements RemoteBootstrapGateway {
  @override
  Future<RemoteProfileSnapshot?> lookupRemoteProfile(OwnerUserId owner) async =>
      null;

  @override
  Future<List<RemoteChange>> pullPostWatermark({
    required RemoteProfileId remoteProfileId,
    required int epoch,
    required int watermark,
  }) async => throw StateError('injected crash at pullPostWatermark');
}

// An inventory with one local-only item and one pending command (+receipt), so
// the copyLocalOnly, rebaseJournal and importReceipts phases all execute.
LocalInventory _inventory() => LocalInventory(
  commitSeq: 12,
  localOnly: <LocalOnlyItem>[
    LocalOnlyItem(kind: LocalOnlyKind.draft, id: 'draft-1', contentHash: 'h1'),
  ],
  receipts: <ReceiptRecord>[
    ReceiptRecord(
      commandId: 'c1',
      requestHash: 'rh',
      resultCode: 'ok',
      payloadVersion: 1,
      commitSeq: 1,
    ),
  ],
  pendingCommands: <PendingCommandRecord>[
    PendingCommandRecord(
      commandId: 'c1',
      commitSeq: 1,
      commandType: 'task.create',
      entityType: 'task',
      entityId: 'fresh-entity',
      canonicalPayload: '{"id":"fresh-entity"}',
      originalResultCode: 'ok',
      originalPayloadVersion: 1,
    ),
  ],
);

/// Wires a coordinator that crashes at [phase], keeping the gate and staged
/// builder reachable for post-crash assertions.
final class _Rig {
  _Rig(BootstrapPhase phase)
    : gate = _CrashGate(
        throwOn:
            (phase == BootstrapPhase.closeAdmission ||
                phase == BootstrapPhase.awaitActiveTransactions ||
                phase == BootstrapPhase.settleSyncWorkers)
            ? phase
            : null,
      ),
      builder = _CrashStagedGenerationBuilder(
        failBuild: phase == BootstrapPhase.buildStaging,
        crashOn: switch (phase) {
          BootstrapPhase.copyLocalOnly => _CrashPoint.copyLocalOnly,
          BootstrapPhase.importReceipts => _CrashPoint.importReceipt,
          BootstrapPhase.activate => _CrashPoint.activate,
          _ => null,
        },
      ) {
    coordinator = SyncBootstrapCoordinator(
      gate: gate,
      inventory: phase == BootstrapPhase.inventory
          ? _ThrowingInventory()
          : FakeLocalGenerationInventory(_inventory()),
      stagedBuilder: builder,
      rebaser: phase == BootstrapPhase.rebaseJournal
          ? _ThrowingRebaser()
          : const JournalReplayRebaser(),
      gateway: phase == BootstrapPhase.pullPostWatermark
          ? _ThrowingGateway()
          : FakeRemoteBootstrapGateway(pullPage: <RemoteChange>[]),
      verifier: phase == BootstrapPhase.verify
          ? FakeManifestVerifier(failureReason: 'injected verify failure')
          : FakeManifestVerifier(),
    );
  }

  final _CrashGate gate;
  final _CrashStagedGenerationBuilder builder;
  late final SyncBootstrapCoordinator coordinator;

  Future<BootstrapSession> begin() => coordinator.begin(
    profile: _profile,
    remoteProfileId: _remote,
    serverEpoch: 5,
    watermark: 0,
    trigger: BootstrapTrigger.stagedMerge,
  );
}

void main() {
  // Every begin-time phase, in normative order.
  const List<BootstrapPhase> beginPhases = <BootstrapPhase>[
    BootstrapPhase.closeAdmission,
    BootstrapPhase.awaitActiveTransactions,
    BootstrapPhase.settleSyncWorkers,
    BootstrapPhase.inventory,
    BootstrapPhase.buildStaging,
    BootstrapPhase.copyLocalOnly,
    BootstrapPhase.rebaseJournal,
    BootstrapPhase.importReceipts,
    BootstrapPhase.pullPostWatermark,
    BootstrapPhase.verify,
  ];

  group('SyncBootstrapCoordinator crash boundaries (begin)', () {
    for (final BootstrapPhase phase in beginPhases) {
      testWithEvidence(
        _evidence('BEGIN-${phase.name.toUpperCase()}'),
        'a failure during ${phase.name} aborts with a phase-tagged exception, '
        'discards staging, and reopens admission',
        () async {
          final _Rig rig = _Rig(phase);
          await expectLater(
            rig.begin(),
            throwsA(
              isA<BootstrapException>().having(
                (BootstrapException e) => e.phase,
                'phase',
                phase,
              ),
            ),
          );

          // Admission is always reopened: the app is never wedged.
          expect(rig.gate.isAdmitting, isTrue, reason: phase.name);
          expect(rig.gate.reopenCount, greaterThanOrEqualTo(1));

          // Any staged generation that was built is discarded, never activated.
          final _CrashStagedGeneration? staged = rig.builder.lastOrNull;
          if (staged != null) {
            expect(staged.activated, isFalse, reason: phase.name);
            expect(staged.discarded, isTrue, reason: phase.name);
          } else {
            // A staged generation is absent only when the failure happened at
            // or before buildStaging (the build itself never returned one).
            expect(
              phase.index,
              lessThanOrEqualTo(BootstrapPhase.buildStaging.index),
              reason: '${phase.name} should have built staging',
            );
          }
        },
      );
    }
  });

  group('BootstrapSession crash boundary (activate)', () {
    testWithEvidence(
      _evidence('ACTIVATE-ATOMIC-SWITCH-FAILURE'),
      'a failed atomic activation discards staging, reopens admission, and '
      'never leaves a half-activated generation',
      () async {
        final _Rig rig = _Rig(BootstrapPhase.activate);
        // begin() must fully succeed: the crash is only at the activate seam.
        final BootstrapSession session = await rig.begin();
        expect(session.state, BootstrapSessionState.readyToActivate);
        // While staged, admission stays closed.
        expect(rig.gate.isAdmitting, isFalse);

        await expectLater(
          session.activate(),
          throwsA(
            isA<BootstrapException>().having(
              (BootstrapException e) => e.phase,
              'phase',
              BootstrapPhase.activate,
            ),
          ),
        );

        final _CrashStagedGeneration staged = rig.builder.lastOrNull!;
        expect(staged.activated, isFalse);
        expect(staged.discarded, isTrue);
        expect(session.state, BootstrapSessionState.cancelled);
        // Admission reopened after the failed switch (not wedged).
        expect(rig.gate.isAdmitting, isTrue);
      },
    );

    testWithEvidence(
      _evidence('ACTIVATE-FAILURE-IS-TERMINAL'),
      're-activating after a failed activation is rejected (single resolution)',
      () async {
        final _Rig rig = _Rig(BootstrapPhase.activate);
        final BootstrapSession session = await rig.begin();
        await expectLater(session.activate(), throwsA(isA<Object>()));
        // The session already resolved (cancelled); a second attempt throws.
        await expectLater(session.activate(), throwsStateError);
      },
    );
  });
}
