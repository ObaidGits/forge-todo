/// Widget bridge timeout fail-safe + committed-result idempotency (task 11.4).
///
/// A widget action or snapshot publish crosses into the native container. If
/// that bridge is slow or unavailable, the app must fail safe rather than hang
/// (NFR-REL-004 stale/partial-failure obligation). These tests prove:
///
///   * **Action timeout (R-WIDGET-003):** a handler that does not settle within
///     the bridge's [ForgeWidgetBridge.hostTimeout] returns a retryable
///     `unavailableCapability` failure instead of blocking forever.
///   * **Publish timeout (R-WIDGET-002):** a native host publish that never
///     settles is dropped after the snapshot is retained in the local store,
///     so publishing never blocks and never loses the snapshot.
///   * **Committed-result idempotency after a timeout (R-WIDGET-003,
///     R-GEN-005):** when a slow handler *does* eventually commit, a retry of
///     the same intent replays the SAME committed receipt at the SAME commit
///     sequence and applies NO duplicate effect.
///
/// The action path runs over a real in-memory schema database and the
/// production [ForgeCommandBus] so the committed-result claims are end to end.
///
/// **Validates: Requirements R-WIDGET-002, R-WIDGET-003, R-GEN-005**
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/forge_widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_snapshot_store.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';

import '../../helpers/evidence.dart';
import '../transaction/command_test_support.dart';

/// A handler that runs the real command bus, but only after an external [gate]
/// is released — modelling a slow/unavailable native bridge.
final class _GatedBusHandler implements WidgetCommandHandler {
  _GatedBusHandler(this.harness, this.gate);

  final CommandHarness harness;
  final Completer<void> gate;

  /// The most recent underlying (ungated) command-bus future, so a test can
  /// await the eventual commit that a timeout did not cancel.
  Future<Result<CommittedCommandResult>>? lastRun;

  @override
  bool supports(WidgetIntentAction action) => true;

  @override
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command) {
    final Future<Result<CommittedCommandResult>> run = () async {
      await gate.future;
      final DurableCommand durable = DurableCommand(
        profileId: harness.profileId,
        commandId: CommandId(command.derivedCommandId),
        commandType: 'widget.${command.action.wireName}',
        schemaVersion: 1,
        requestHash: command.canonicalPayload,
        canonicalPayload: command.canonicalPayload,
      );
      return harness.bus.execute(
        durable,
        (session) async => SemanticWrite(
          resultCode: 'applied:${command.targetEntityId}',
          payloadVersion: 1,
          resultPayload: '{"target":"${command.targetEntityId}"}',
          activity: <ActivityDraft>[
            ActivityDraft(
              id: 'act-${command.intentId}',
              eventType: 'widget_action',
              entityType: 'task',
              entityId: command.targetEntityId,
              payloadVersion: 1,
            ),
          ],
        ),
      );
    }();
    lastRun = run;
    return run;
  }
}

/// A host channel whose publish never settles until released.
final class _HangingHostChannel implements WidgetHostChannel {
  final Completer<void> gate = Completer<void>();
  int publishAttempts = 0;

  @override
  Future<void> publish(WidgetSnapshot snapshot) {
    publishAttempts += 1;
    return gate.future;
  }

  @override
  Future<void> clear(WidgetSurface surface) async {}
}

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-TIMEOUT-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.4'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

const String _secret = 'shared-bridge-secret-value';
const Duration _shortTimeout = Duration(milliseconds: 50);

void main() {
  late CommandHarness harness;
  late KeyedHashWidgetIntentSigner signer;
  late InMemoryWidgetSnapshotStore store;

  setUp(() async {
    harness = await CommandHarness.open(initialUtc: DateTime.utc(2024, 6, 1));
    signer = KeyedHashWidgetIntentSigner(secret: _secret);
    store = InMemoryWidgetSnapshotStore();
  });

  tearDown(() async {
    await harness.close();
  });

  WidgetIntent signedIntent(String intentId) {
    final int issued = harness.clock.utcNow().microsecondsSinceEpoch;
    final WidgetIntent unsigned = WidgetIntent(
      intentId: intentId,
      profileId: harness.profileId.value,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: 'task-42',
      issuedAtUtcMicros: issued,
      token: '',
    );
    return WidgetIntent(
      intentId: intentId,
      profileId: harness.profileId.value,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: 'task-42',
      issuedAtUtcMicros: issued,
      token: signer.sign(unsigned.canonicalPayload()),
    );
  }

  WidgetIntentVerifier verifier() => WidgetIntentVerifier(
    signer: signer,
    clock: harness.clock,
    activeProfileId: harness.profileId,
  );

  Future<int> activityCount() => harness.scalarInt(
    'SELECT COUNT(*) AS n FROM activity_events WHERE entity_id = ?',
    <Object?>['task-42'],
  );

  Future<int> receiptCount() => harness.scalarInt(
    'SELECT COUNT(*) AS n FROM command_receipts WHERE command_id = ?',
    <Object?>['widget-tap-1'],
  );

  testWithEvidence(
    _evidence('ACTION-FAILS-SAFE', <String>['R-WIDGET-003']),
    'an action whose handler never settles returns a retryable unavailable '
    'result instead of hanging',
    () async {
      final Completer<void> gate = Completer<void>();
      final _GatedBusHandler handler = _GatedBusHandler(harness, gate);
      final ForgeWidgetBridge bridge = ForgeWidgetBridge(
        verifier: verifier(),
        handlers: <WidgetCommandHandler>[handler],
        channel: _HangingHostChannel(),
        snapshots: store,
        hostTimeout: _shortTimeout,
      );

      final Result<CommittedCommandResult> result = await bridge.execute(
        signedIntent('tap-1'),
      );

      expect(result, isA<Failed<CommittedCommandResult>>());
      final Failure failure =
          (result as Failed<CommittedCommandResult>).failure;
      expect(failure.kind, FailureKind.unavailableCapability);
      expect(failure.retryable, isTrue);
      expect(failure.code, startsWith('widget.action_timeout'));

      // Release the gate so the still-running command settles, then clean up.
      gate.complete();
      await handler.lastRun;
    },
  );

  testWithEvidence(
    _evidence('PUBLISH-FAILS-SAFE', <String>['R-WIDGET-002']),
    'a publish to an unresponsive native host is dropped after the snapshot is '
    'retained locally, without blocking',
    () async {
      final _HangingHostChannel channel = _HangingHostChannel();
      final ForgeWidgetBridge bridge = ForgeWidgetBridge(
        verifier: verifier(),
        handlers: const <WidgetCommandHandler>[],
        channel: channel,
        snapshots: store,
        hostTimeout: _shortTimeout,
      );
      final WidgetSnapshot snapshot = WidgetSnapshot(
        version: WidgetSnapshot.currentVersion,
        surfaceWire: WidgetSurface.todayTasks.wireName,
        profileId: harness.profileId.value,
        generatedAtUtcMicros: harness.clock.utcNow().microsecondsSinceEpoch,
        stalenessThresholdSeconds: 1800,
        redacted: false,
        items: <WidgetSnapshotItem>[
          WidgetSnapshotItem(id: 'task-1', title: 'Ship widgets'),
        ],
      );

      // Completes despite the hung host (bounded by hostTimeout).
      await bridge.publish(snapshot);

      expect(channel.publishAttempts, 1);
      // The snapshot is durable locally for the next reconcile.
      expect(await store.load(WidgetSurface.todayTasks), snapshot);
    },
  );

  testWithEvidence(
    _evidence('IDEMPOTENT-AFTER-TIMEOUT', <String>[
      'R-WIDGET-003',
      'R-GEN-005',
    ]),
    'a slow action that times out but still commits replays the same receipt on '
    'retry and applies no duplicate effect',
    () async {
      final Completer<void> gate = Completer<void>();
      final _GatedBusHandler handler = _GatedBusHandler(harness, gate);
      final ForgeWidgetBridge bridge = ForgeWidgetBridge(
        verifier: verifier(),
        handlers: <WidgetCommandHandler>[handler],
        channel: _HangingHostChannel(),
        snapshots: store,
        hostTimeout: _shortTimeout,
      );

      final WidgetIntent intent = signedIntent('tap-1');

      // First attempt times out (gate still closed) but the underlying command
      // keeps running.
      final Result<CommittedCommandResult> first = await bridge.execute(intent);
      expect(first, isA<Failed<CommittedCommandResult>>());
      expect(
        (first as Failed<CommittedCommandResult>).failure.retryable,
        isTrue,
      );

      // Let the slow command actually commit.
      gate.complete();
      final Result<CommittedCommandResult> committed = (await handler.lastRun!);
      expect(committed, isA<Success<CommittedCommandResult>>());
      expect(await receiptCount(), 1);
      expect(await activityCount(), 1);

      // Retry the same intent: the receipt short-circuits, replaying the same
      // committed result with no duplicate effect.
      final Result<CommittedCommandResult> retry = await bridge.execute(intent);
      final CommittedCommandResult receipt =
          (retry as Success<CommittedCommandResult>).value;
      expect(receipt.replayed, isTrue);
      expect(
        receipt.resultCode,
        (committed as Success<CommittedCommandResult>).value.resultCode,
      );
      expect(receipt.commitSeq, committed.value.commitSeq);
      expect(await receiptCount(), 1, reason: 'no duplicate receipt');
      expect(await activityCount(), 1, reason: 'no duplicate effect');
    },
  );
}
