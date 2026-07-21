/// The mandatory post-maintenance-gate command quiescence (R-SYNC-006,
/// NFR-REL-004; design.md §12, testing.md §4 "mandatory post-maintenance-gate
/// command quiescence").
///
/// [CommandQuiescenceGate] is the reference [MaintenanceGate]: it closes command
/// admission, drives the two blocking quiescence steps (await active
/// transactions, stop/settle sync workers) via injected hooks, and rejects any
/// command admitted while closed with a *retryable* maintenance failure so the
/// caller retries rather than dropping the command. The coordinator suite
/// exercises it end to end; this suite pins the gate's own contract.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/bootstrap/command_quiescence_gate.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-006'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-QUIESCENCE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.9'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

void main() {
  group('CommandQuiescenceGate admission', () {
    testWithEvidence(
      _evidence('OPEN-BY-DEFAULT'),
      'a fresh gate admits commands',
      () {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        expect(gate.isAdmitting, isTrue);
        expect(gate.admit(), isA<Success<void>>());
      },
    );

    testWithEvidence(
      _evidence(
        'CLOSED-REJECTS-RETRYABLY',
        requirements: <String>['R-SYNC-006', 'NFR-REL-004'],
      ),
      'a closed gate rejects with a retryable maintenance-locked failure',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        await gate.closeAdmission();
        expect(gate.isAdmitting, isFalse);
        final Result<void> result = gate.admit();
        expect(result, isA<Failed<void>>());
        final Failure failure = result.failureOrNull!;
        expect(failure.code, kMaintenanceInProgressCode);
        expect(failure.kind, FailureKind.maintenanceLocked);
        expect(failure.retryable, isTrue);
        expect(failure.safeMessageKey, 'error.sync.maintenance_in_progress');
      },
    );

    testWithEvidence(
      _evidence('REOPEN-ADMITS-AGAIN'),
      'reopening admission after quiescence admits commands again',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        await gate.closeAdmission();
        await gate.reopenAdmission();
        expect(gate.isAdmitting, isTrue);
        expect(gate.admit(), isA<Success<void>>());
      },
    );
  });

  group('CommandQuiescenceGate quiescence hooks', () {
    testWithEvidence(
      _evidence('AWAITS-TRANSACTIONS-THEN-WORKERS-IN-ORDER'),
      'closing then quiescing awaits active transactions then settles workers, '
      'each exactly once and in order',
      () async {
        final List<String> events = <String>[];
        final CommandQuiescenceGate gate = CommandQuiescenceGate(
          awaitTransactions: () async => events.add('await-transactions'),
          settleWorkers: () async => events.add('settle-workers'),
        );

        await gate.closeAdmission();
        // Closing resets the quiescence flags until the steps run.
        expect(gate.transactionsAwaited, isFalse);
        expect(gate.workersSettled, isFalse);

        await gate.awaitActiveTransactions();
        expect(gate.transactionsAwaited, isTrue);
        expect(gate.workersSettled, isFalse);

        await gate.settleSyncWorkers();
        expect(gate.workersSettled, isTrue);

        // Both hooks ran exactly once, transactions before workers.
        expect(events, <String>['await-transactions', 'settle-workers']);
      },
    );

    testWithEvidence(
      _evidence('CLOSING-RESETS-QUIESCENCE-FLAGS'),
      'a second close resets the quiescence flags for the new cycle',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        await gate.closeAdmission();
        await gate.awaitActiveTransactions();
        await gate.settleSyncWorkers();
        expect(gate.transactionsAwaited, isTrue);
        expect(gate.workersSettled, isTrue);

        await gate.reopenAdmission();
        await gate.closeAdmission();
        // The new maintenance cycle must re-run quiescence.
        expect(gate.transactionsAwaited, isFalse);
        expect(gate.workersSettled, isFalse);
      },
    );

    testWithEvidence(
      _evidence('DEFAULT-HOOKS-ARE-NOOP'),
      'the default hooks complete without error and set the flags',
      () async {
        final CommandQuiescenceGate gate = CommandQuiescenceGate();
        await gate.closeAdmission();
        await gate.awaitActiveTransactions();
        await gate.settleSyncWorkers();
        expect(gate.transactionsAwaited, isTrue);
        expect(gate.workersSettled, isTrue);
      },
    );
  });
}
