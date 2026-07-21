/// Widget intent idempotency + committed receipts, over the real command bus.
///
/// Proves the action path of the widget bridge foundation end to end against a
/// real in-memory schema database and the production [ForgeCommandBus]:
///
///   * a verified widget intent routes through an idempotent durable command
///     and returns a COMMITTED receipt, not a dispatch acknowledgement
///     (R-WIDGET-003, R-GEN-005);
///   * a double-tap / re-delivered intent (same intent id) returns the SAME
///     committed receipt at the SAME commit sequence and applies NO duplicate
///     effect;
///   * a spoofed intent is rejected before any command runs, leaving no
///     receipt, activity, or commit-log row;
///   * publishing a snapshot is a local-only side effect.
///
/// **Validates: Requirements R-WIDGET-002, R-WIDGET-003, R-WIDGET-004**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/forge_widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_host_channel.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_snapshot_store.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';

import '../../helpers/evidence.dart';
import '../transaction/command_test_support.dart';

/// A widget command handler that runs the verified command through the real
/// command bus, mirroring how a feature command service commits an action.
final class _BusWidgetCommandHandler implements WidgetCommandHandler {
  _BusWidgetCommandHandler(this.harness);

  final CommandHarness harness;

  @override
  bool supports(WidgetIntentAction action) => true;

  @override
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command) {
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
  }
}

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-BRIDGE-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.1'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

const String _secret = 'shared-bridge-secret-value';

void main() {
  late CommandHarness harness;
  late KeyedHashWidgetIntentSigner signer;
  late InMemoryWidgetHostChannel channel;
  late InMemoryWidgetSnapshotStore store;
  late ForgeWidgetBridge bridge;

  setUp(() async {
    harness = await CommandHarness.open(initialUtc: DateTime.utc(2024, 6, 1));
    signer = KeyedHashWidgetIntentSigner(secret: _secret);
    channel = InMemoryWidgetHostChannel();
    store = InMemoryWidgetSnapshotStore();
    bridge = ForgeWidgetBridge(
      verifier: WidgetIntentVerifier(
        signer: signer,
        clock: harness.clock,
        activeProfileId: harness.profileId,
      ),
      handlers: <WidgetCommandHandler>[_BusWidgetCommandHandler(harness)],
      channel: channel,
      snapshots: store,
    );
  });

  tearDown(() async {
    await harness.close();
  });

  WidgetIntent signedIntent({
    required String intentId,
    String targetEntityId = 'task-42',
    String? profileIdOverride,
    String? tokenOverride,
  }) {
    final int issued = harness.clock.utcNow().microsecondsSinceEpoch;
    final String profileId = profileIdOverride ?? harness.profileId.value;
    final WidgetIntent unsigned = WidgetIntent(
      intentId: intentId,
      profileId: profileId,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: targetEntityId,
      issuedAtUtcMicros: issued,
      token: '',
    );
    return WidgetIntent(
      intentId: intentId,
      profileId: profileId,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: targetEntityId,
      issuedAtUtcMicros: issued,
      token: tokenOverride ?? signer.sign(unsigned.canonicalPayload()),
    );
  }

  Future<int> activityCount(String entityId) => harness.scalarInt(
    'SELECT COUNT(*) AS n FROM activity_events WHERE entity_id = ?',
    <Object?>[entityId],
  );

  Future<int> receiptCount(String commandId) => harness.scalarInt(
    'SELECT COUNT(*) AS n FROM command_receipts WHERE command_id = ?',
    <Object?>[commandId],
  );

  testWithEvidence(
    _evidence('COMMITTED-RECEIPT', <String>['R-WIDGET-003']),
    'a verified intent returns a committed receipt from the command bus',
    () async {
      final Result<CommittedCommandResult> result = await bridge.execute(
        signedIntent(intentId: 'tap-1'),
      );
      expect(result, isA<Success<CommittedCommandResult>>());
      final CommittedCommandResult receipt =
          (result as Success<CommittedCommandResult>).value;
      expect(receipt.replayed, isFalse);
      expect(receipt.resultCode, 'applied:task-42');
      expect(receipt.commitSeq, greaterThan(0));
      expect(await receiptCount('widget-tap-1'), 1);
      expect(await activityCount('task-42'), 1);
    },
  );

  testWithEvidence(
    _evidence('IDEMPOTENT-REPLAY', <String>['R-WIDGET-003']),
    'a re-delivered intent (double-tap) returns the same receipt and applies no '
    'duplicate effect',
    () async {
      final WidgetIntent intent = signedIntent(intentId: 'tap-1');
      final Result<CommittedCommandResult> first = await bridge.execute(intent);
      final Result<CommittedCommandResult> second = await bridge.execute(
        intent,
      );

      final CommittedCommandResult a =
          (first as Success<CommittedCommandResult>).value;
      final CommittedCommandResult b =
          (second as Success<CommittedCommandResult>).value;

      expect(a.replayed, isFalse);
      expect(b.replayed, isTrue, reason: 'replay must hit the stored receipt');
      expect(b.resultCode, a.resultCode);
      expect(b.commitSeq, a.commitSeq, reason: 'same committed sequence');

      // No duplicate effect: exactly one receipt and one activity row.
      expect(await receiptCount('widget-tap-1'), 1);
      expect(await activityCount('task-42'), 1);
    },
  );

  testWithEvidence(
    _evidence('SPOOF-NO-EFFECT', <String>['R-WIDGET-003']),
    'a spoofed intent is rejected and commits nothing',
    () async {
      final Result<CommittedCommandResult> result = await bridge.execute(
        signedIntent(intentId: 'tap-1', tokenOverride: 'ff' * 32),
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'widget.intent_rejected.invalidSignature',
      );
      expect(await receiptCount('widget-tap-1'), 0);
      expect(await activityCount('task-42'), 0);
    },
  );

  testWithEvidence(
    _evidence('CROSS-PROFILE-NO-EFFECT', <String>['R-WIDGET-003']),
    'a correctly-signed intent for another profile commits nothing',
    () async {
      final Result<CommittedCommandResult> result = await bridge.execute(
        signedIntent(intentId: 'tap-1', profileIdOverride: 'other-profile'),
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(await receiptCount('widget-tap-1'), 0);
      expect(await activityCount('task-42'), 0);
    },
  );

  testWithEvidence(
    _evidence('PUBLISH-LOCAL-ONLY', <String>['R-WIDGET-002', 'R-WIDGET-004']),
    'publishing a snapshot stores it locally and pushes it to the container '
    'without enqueuing any outbox work',
    () async {
      final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
        clock: harness.clock,
      );
      final WidgetSnapshot snapshot = builder.build(
        surface: WidgetSurface.todayTasks,
        profileId: harness.profileId,
        items: <WidgetSnapshotItem>[
          WidgetSnapshotItem(id: 'task-1', title: 'Ship widgets'),
        ],
        contentVisible: true,
      );
      await bridge.publish(snapshot);

      expect(channel.publishCount, 1);
      expect(channel.read(WidgetSurface.todayTasks), snapshot);
      expect(await store.load(WidgetSurface.todayTasks), snapshot);

      // Local-only: publishing must not create any sync outbox rows.
      final int outbox = await harness.scalarInt(
        'SELECT COUNT(*) AS n FROM outbox_mutations',
      );
      expect(outbox, 0);
    },
  );
}
