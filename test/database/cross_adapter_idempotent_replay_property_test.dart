/// Property 3 — Idempotent replay across every command-bearing adapter.
///
/// The same logical action can arrive at Forge through four independent
/// adapters, and each may be *re-delivered* arbitrarily (an OS re-fires a
/// notification action, a widget double-taps, a pull page is re-received, a UI
/// command is retried). This property proves that replaying the SAME logical
/// action through EACH adapter converges on exactly-once effects with a stable
/// committed result — never a duplicate row and never a divergent receipt:
///
///   1. **Direct command (R-GEN-005)** — the real [ForgeCommandBus] dedupes by
///      `(profile_id, command_id)`; a replay returns the stored receipt verbatim
///      (same result code / payload / `commit_seq`) and commits nothing new.
///   2. **Sync operation apply (R-SYNC-003)** — re-applying the same translated
///      pull page through the production [PullApplyCoordinator] +
///      `AppliedOperationRepository` is a harmless duplicate no-op: the cursor
///      is stable and no applier effect is duplicated.
///   3. **Notification action (R-NOTIFY-005)** — a re-delivered notification
///      action maps to the same durable command through [ReminderActionService]
///      and replays the same committed receipt before any OS dismissal.
///   4. **Widget action (R-WIDGET-003)** — a re-delivered widget intent maps to
///      the same derived command through [ForgeWidgetBridge] and replays the
///      same committed receipt.
///
/// All four adapters run over ONE real in-memory Drift database and share the
/// production command bus, receipts, pull coordinator, notification-action
/// mapping and widget bridge. Each seeded, deterministic scenario generates a
/// random interleaving of first-deliveries and arbitrary re-deliveries across
/// all four adapters, then asserts that (a) every adapter's committed result is
/// identical on every delivery, (b) exactly one delivery per adapter performed
/// the durable commit, and (c) the durable effect counts are exactly one — no
/// duplicate receipt, activity, applied-operation, or entity row. No wall
/// clock, no network, no random identity: any counterexample is reproducible by
/// its seed.
///
/// **Property 3: Idempotent replay**
/// **Validates: Requirements R-GEN-005, R-SYNC-003, R-NOTIFY-005, R-WIDGET-003**
library;

import 'dart:math';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/sync/pull_apply_coordinator.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/reminder_action_service.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/infrastructure/reminder_command_service_drift.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repository_factories.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:forge/features/widgets/application/forge_widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_host_channel.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_snapshot_store.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';

import '../helpers/evidence.dart';
import '../helpers/fake_clock.dart';
import '../helpers/fake_id_generator.dart';
import 'notifications/reminder_test_support.dart';
import 'schema/schema_test_database.dart';
import 'tasks/task_test_support.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-XADAPTER-IDEMPOTENT-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('11.5'),
  requirements: <RequirementId>[
    RequirementId('R-GEN-005'),
    RequirementId('R-SYNC-003'),
    RequirementId('R-NOTIFY-005'),
    RequirementId('R-WIDGET-003'),
  ],
);

/// The four command-bearing adapters this property spans.
enum _Adapter { directCommand, syncApply, notificationAction, widgetAction }

const String _widgetSecret = 'shared-bridge-secret-value-x11-5';

void main() {
  const int caseCount = 160;

  group('given all four adapters over one real Drift DB', () {
    testWithEvidence(
      _evidence('PROP-001'),
      'a random interleaving of first-deliveries and arbitrary re-deliveries '
      'across the direct command, sync apply, notification action, and widget '
      'action adapters converges on a stable committed result per adapter and '
      'exactly-once durable effects',
      () async {
        int totalRedeliveries = 0;
        final Map<_Adapter, int> deliveredAdapters = <_Adapter, int>{
          for (final _Adapter a in _Adapter.values) a: 0,
        };
        for (int seed = 0; seed < caseCount; seed += 1) {
          final _RunStats stats = await _runScenario(seed);
          totalRedeliveries += stats.redeliveries;
          for (final _Adapter a in _Adapter.values) {
            deliveredAdapters[a] = deliveredAdapters[a]! + stats.deliveries[a]!;
          }
        }
        // The property is vacuous unless the scenarios actually re-delivered
        // logical actions and exercised every adapter.
        expect(
          totalRedeliveries,
          greaterThan(0),
          reason: 'no scenario re-delivered an action; replay path untested',
        );
        for (final _Adapter adapter in _Adapter.values) {
          expect(
            deliveredAdapters[adapter],
            greaterThan(0),
            reason: 'adapter ${adapter.name} was never exercised',
          );
        }
      },
    );
  });

  group('Idempotent replay examples', () {
    testWithEvidence(
      _evidence('DIRECT-COMMAND-REPLAY'),
      'the command bus replays the stored receipt at the same commit sequence '
      'and commits no duplicate effect (R-GEN-005)',
      () async {
        final _XAdapterHarness h = await _XAdapterHarness.open();
        try {
          final _Committed first = await h.deliverDirectCommand();
          final _Committed second = await h.deliverDirectCommand();
          expect(first.freshCommit, isTrue);
          expect(second.freshCommit, isFalse, reason: 'replay must be stored');
          expect(second.identity, first.identity);
          expect(await h.directReceiptCount(), 1);
          expect(await h.directActivityCount(), 1);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('SYNC-APPLY-DUPLICATE-NOOP'),
      're-applying the same translated pull page is a harmless duplicate no-op '
      'with a stable cursor and no duplicated applier effect (R-SYNC-003)',
      () async {
        final _XAdapterHarness h = await _XAdapterHarness.open();
        try {
          final _Committed first = await h.deliverSyncApply();
          final _Committed second = await h.deliverSyncApply();
          expect(first.freshCommit, isTrue);
          expect(
            second.freshCommit,
            isFalse,
            reason: 'replay must be duplicate',
          );
          expect(second.identity, first.identity, reason: 'cursor stable');
          expect(await h.appliedOperationCount(), 1);
          expect(await h.syncEntityCount(), 1);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('NOTIFICATION-ACTION-REPLAY'),
      'a re-delivered notification action maps to the same durable command and '
      'replays the same committed receipt before any dismissal (R-NOTIFY-005)',
      () async {
        final _XAdapterHarness h = await _XAdapterHarness.open();
        try {
          final _Committed first = await h.deliverNotificationAction();
          final _Committed second = await h.deliverNotificationAction();
          expect(first.freshCommit, isTrue);
          expect(second.freshCommit, isFalse, reason: 'replay must be stored');
          expect(second.identity, first.identity);
          expect(await h.notificationReceiptCount(), 1);
          expect(await h.notificationActivityCount(), 1);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('WIDGET-ACTION-REPLAY'),
      'a re-delivered widget intent maps to the same derived command and '
      'replays the same committed receipt (R-WIDGET-003)',
      () async {
        final _XAdapterHarness h = await _XAdapterHarness.open();
        try {
          final _Committed first = await h.deliverWidgetAction();
          final _Committed second = await h.deliverWidgetAction();
          expect(first.freshCommit, isTrue);
          expect(second.freshCommit, isFalse, reason: 'replay must be stored');
          expect(second.identity, first.identity);
          expect(await h.widgetReceiptCount(), 1);
          expect(await h.widgetActivityCount(), 1);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('INTERLEAVED-ALL-FOUR'),
      'first-delivering all four adapters then re-delivering each once yields '
      'exactly-once effects and stable committed results everywhere',
      () async {
        final _XAdapterHarness h = await _XAdapterHarness.open();
        try {
          final Map<_Adapter, _Committed> firsts = <_Adapter, _Committed>{
            _Adapter.directCommand: await h.deliver(_Adapter.directCommand),
            _Adapter.widgetAction: await h.deliver(_Adapter.widgetAction),
            _Adapter.notificationAction: await h.deliver(
              _Adapter.notificationAction,
            ),
            _Adapter.syncApply: await h.deliver(_Adapter.syncApply),
          };
          for (final _Adapter adapter in _Adapter.values) {
            final _Committed replay = await h.deliver(adapter);
            expect(replay.freshCommit, isFalse);
            expect(replay.identity, firsts[adapter]!.identity);
          }
          await h.expectExactlyOnceEffects();
        } finally {
          await h.close();
        }
      },
    );
  });
}

/// Per-scenario coverage counters, used only to keep the property non-vacuous.
final class _RunStats {
  _RunStats({required this.redeliveries, required this.deliveries});

  final int redeliveries;
  final Map<_Adapter, int> deliveries;
}

/// Drives one seeded scenario: build a randomized interleaving of deliveries in
/// which every adapter is delivered at least twice (one first-delivery plus one
/// or more re-deliveries), then assert stability and exactly-once effects.
Future<_RunStats> _runScenario(int seed) async {
  final Random rng = Random(seed);
  final _XAdapterHarness h = await _XAdapterHarness.open();
  final String describe = 'seed=$seed';
  try {
    // Build a delivery bag: each adapter appears 2..4 times so at least one
    // re-delivery is guaranteed per adapter.
    final List<_Adapter> bag = <_Adapter>[];
    final Map<_Adapter, int> deliveries = <_Adapter, int>{
      for (final _Adapter a in _Adapter.values) a: 0,
    };
    for (final _Adapter adapter in _Adapter.values) {
      final int count = 2 + rng.nextInt(3); // 2..4
      for (int i = 0; i < count; i += 1) {
        bag.add(adapter);
      }
      deliveries[adapter] = count;
    }
    bag.shuffle(rng);

    // Execute the interleaving. Each adapter's own deliveries stay in order
    // (first occurrence is the first-delivery), so the first observed committed
    // identity is the reference every later delivery must match.
    final Map<_Adapter, _Committed> reference = <_Adapter, _Committed>{};
    final Map<_Adapter, int> freshCommits = <_Adapter, int>{
      for (final _Adapter a in _Adapter.values) a: 0,
    };
    int redeliveries = 0;

    for (final _Adapter adapter in bag) {
      final _Committed committed = await h.deliver(adapter);
      if (committed.freshCommit) {
        freshCommits[adapter] = freshCommits[adapter]! + 1;
      }
      final _Committed? ref = reference[adapter];
      if (ref == null) {
        reference[adapter] = committed;
        expect(
          committed.freshCommit,
          isTrue,
          reason: '$describe: first delivery of ${adapter.name} must commit',
        );
      } else {
        redeliveries += 1;
        expect(
          committed.freshCommit,
          isFalse,
          reason:
              '$describe: re-delivery of ${adapter.name} committed a duplicate',
        );
        expect(
          committed.identity,
          ref.identity,
          reason:
              '$describe: ${adapter.name} returned a divergent committed result '
              'on replay',
        );
      }
    }

    // Exactly one delivery per adapter performed the durable commit.
    for (final _Adapter adapter in _Adapter.values) {
      expect(
        freshCommits[adapter],
        1,
        reason:
            '$describe: ${adapter.name} performed ${freshCommits[adapter]} '
            'durable commits (expected exactly one)',
      );
    }

    // No duplicate durable effect anywhere.
    await h.expectExactlyOnceEffects(describe: describe);

    return _RunStats(redeliveries: redeliveries, deliveries: deliveries);
  } finally {
    await h.close();
  }
}

/// The normalized committed outcome of a single delivery through any adapter.
final class _Committed {
  const _Committed({required this.identity, required this.freshCommit});

  /// A stable string capturing the committed result (receipt result/payload/
  /// commit sequence, or the sync cursor). Identical across every delivery of
  /// the same logical action.
  final String identity;

  /// True only for the delivery that performed the first durable commit; false
  /// for every idempotent replay / duplicate no-op.
  final bool freshCommit;
}

/// Wires all four adapters over ONE in-memory schema database sharing the
/// production command bus, receipts, pull coordinator, notification-action
/// mapping, and widget bridge.
final class _XAdapterHarness {
  _XAdapterHarness._({
    required this.db,
    required this.profileId,
    required this.clock,
    required this.bus,
    required this.reminderActions,
    required this.widgetBridge,
    required this.translator,
    required this.widgetIntent,
  });

  static const String _backend = 'supabase';
  static const String _remoteProfileId = 'remote-1';

  // Stable logical identities for each adapter's action.
  static const String _directCommandId = 'cmd-direct';
  static const String _directActivityId = 'act-direct';
  static const String _directEntityId = 'entity-direct';

  static const String _syncChangeId = 'chg-sync';
  static const String _syncEntityId = 'tag-sync';

  static const String _reminderId = 'rem-notify';
  static const String _notifyActionCommandId = 'cmd-notify-action';

  static const String _widgetIntentId = 'tap-widget';
  static const String _widgetTargetId = 'task-widget';

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final FakeClock clock;
  final ForgeCommandBus bus;
  final ReminderActionService reminderActions;
  final ForgeWidgetBridge widgetBridge;
  final PullTranslator translator;
  final WidgetIntent widgetIntent;

  static Future<_XAdapterHarness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    // A concrete owner task for the reminder / widget action target.
    await db.customStatement(
      'INSERT INTO tasks '
      '(id, profile_id, life_area_id, title, status, priority, rank, '
      'created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        _widgetTargetId,
        profileId,
        'area-1',
        'Owner task',
        'open',
        'none',
        'm',
        0,
        0,
      ],
    );
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12));
    final FakeIdGenerator ids = FakeIdGenerator.sequential();

    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...reminderRepositoryFactories,
        ...taskRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
    );

    // --- Sync adapter wiring: real link + translator + coordinator. ---------
    final SyncProfileLink link = SyncProfileLink(
      localProfileId: ProfileId(profileId),
      backend: _backend,
      ownerUserId: OwnerUserId('owner-1'),
      remoteProfileId: RemoteProfileId(_remoteProfileId),
      state: SyncLinkState.linked,
    );
    final PullTranslator translator = PullTranslator(
      SyncIdentityTranslator(link),
    );

    // --- Notification adapter wiring: real command services + transport. ----
    final DriftReminderCommandService reminderCommands =
        DriftReminderCommandService(bus: bus, clock: clock, idGenerator: ids);
    final DriftTaskCommandService taskCommands = DriftTaskCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final FakeNotificationTransport transport = FakeNotificationTransport();
    final ReminderActionService reminderActions = ReminderActionService(
      reminderCommands: reminderCommands,
      transport: transport,
      taskCommands: taskCommands,
    );

    // A durable reminder must exist before its action can be acknowledged.
    final Result<CommittedCommandResult> created = await reminderCommands
        .create(
          commandId: CommandId('cmd-notify-create'),
          profileId: ProfileId(profileId),
          reminderId: ReminderId(_reminderId),
          input: CreateReminderInput(
            ownerType: ReminderOwnerType.task,
            ownerId: _widgetTargetId,
            triggerKind: ReminderTriggerKind.absolute,
            timezoneId: 'Etc/UTC',
            absoluteLocal: LocalDateTime(
              LocalDate(2024, 6, 30),
              LocalTime(9, 0),
            ),
          ),
        );
    if (created is Failed<CommittedCommandResult>) {
      throw StateError('reminder setup failed: ${created.failure.code}');
    }

    // --- Widget adapter wiring: signer + verifier + bus-backed handler. ------
    final KeyedHashWidgetIntentSigner signer = KeyedHashWidgetIntentSigner(
      secret: _widgetSecret,
    );
    final ForgeWidgetBridge widgetBridge = ForgeWidgetBridge(
      verifier: WidgetIntentVerifier(
        signer: signer,
        clock: clock,
        activeProfileId: ProfileId(profileId),
      ),
      handlers: <WidgetCommandHandler>[
        _BusWidgetCommandHandler(bus, ProfileId(profileId)),
      ],
      channel: InMemoryWidgetHostChannel(),
      snapshots: InMemoryWidgetSnapshotStore(),
    );

    final int issued = clock.utcNow().microsecondsSinceEpoch;
    final WidgetIntent unsigned = WidgetIntent(
      intentId: _widgetIntentId,
      profileId: profileId,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: _widgetTargetId,
      issuedAtUtcMicros: issued,
      token: '',
    );
    final WidgetIntent widgetIntent = WidgetIntent(
      intentId: _widgetIntentId,
      profileId: profileId,
      action: WidgetIntentAction.completeTask,
      surfaceWire: WidgetSurface.todayTasks.wireName,
      targetEntityId: _widgetTargetId,
      issuedAtUtcMicros: issued,
      token: signer.sign(unsigned.canonicalPayload()),
    );

    return _XAdapterHarness._(
      db: db,
      profileId: ProfileId(profileId),
      clock: clock,
      bus: bus,
      reminderActions: reminderActions,
      widgetBridge: widgetBridge,
      translator: translator,
      widgetIntent: widgetIntent,
    );
  }

  Future<void> close() => db.close();

  /// Delivers [adapter]'s logical action once.
  Future<_Committed> deliver(_Adapter adapter) => switch (adapter) {
    _Adapter.directCommand => deliverDirectCommand(),
    _Adapter.syncApply => deliverSyncApply(),
    _Adapter.notificationAction => deliverNotificationAction(),
    _Adapter.widgetAction => deliverWidgetAction(),
  };

  // --- 1. Direct command (R-GEN-005) --------------------------------------

  Future<_Committed> deliverDirectCommand() async {
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: CommandId(_directCommandId),
      commandType: 'task.create',
      schemaVersion: 1,
      requestHash: 'hash-direct',
      canonicalPayload: '{"intent":"create","id":"$_directEntityId"}',
    );
    final Result<CommittedCommandResult> result = await bus.execute(
      command,
      (TransactionSession session) async => const SemanticWrite(
        resultCode: 'created',
        payloadVersion: 1,
        resultPayload: '{"id":"$_directEntityId"}',
        activity: <ActivityDraft>[
          ActivityDraft(
            id: _directActivityId,
            eventType: 'created',
            entityType: 'task',
            entityId: _directEntityId,
            payloadVersion: 1,
          ),
        ],
      ),
    );
    return _fromCommandResult('direct', result);
  }

  // --- 2. Sync operation apply (R-SYNC-003) -------------------------------

  Future<_Committed> deliverSyncApply() async {
    final SyncCursor cursor = await _readCursor();
    final PullPage page = PullPage(
      remoteProfileId: RemoteProfileId(_remoteProfileId),
      epoch: SnapshotEpoch(0),
      fromSeq: ServerSeq(0),
      toSeq: ServerSeq(1),
      changes: <RemoteChange>[
        RemoteChange(
          changeId: _syncChangeId,
          entityType: 'tag',
          entityId: _syncEntityId,
          kind: SyncOperationKind.insert,
          serverSeq: ServerSeq(1),
          serverVersion: 1,
          payload: const <String, Object?>{
            'normalized_name': 'sync',
            'display_name': 'Sync',
          },
        ),
      ],
      nextCursor: SyncCursor(epoch: SnapshotEpoch(0), serverSeq: ServerSeq(1)),
    );
    final TranslatedPullPage translated = translator.translate(
      page: page,
      cursor: cursor,
    );
    final PullApplyCoordinator coordinator = PullApplyCoordinator(
      unitOfWork: DriftUnitOfWork(
        db,
        activeProfileResolver: () => profileId.value,
      ),
      appliers: RemoteApplierRegistry(<RemoteApplier>[
        _TagApplier(db, profileId),
      ]),
      clock: clock,
    );
    final PullApplyResult result = await coordinator.applyPage(
      PullApplyRequest(
        page: translated,
        backend: _backend,
        dirtyProjections: const <DirtyProjectionMarker>[
          DirtyProjectionMarker(
            projection: 'search',
            projectionKey: _syncEntityId,
          ),
        ],
      ),
    );
    // The committed result is the stable advanced cursor; a re-pull is a
    // duplicate no-op that returns the same cursor and applies nothing.
    final String identity =
        'cursor:${result.cursor.epoch.value}:${result.cursor.serverSeq.value}';
    return _Committed(
      identity: identity,
      freshCommit: result.outcome == PullApplyOutcome.applied,
    );
  }

  // --- 3. Notification action (R-NOTIFY-005) ------------------------------

  Future<_Committed> deliverNotificationAction() async {
    final Result<ReminderActionResult> result = await reminderActions.handle(
      commandId: CommandId(_notifyActionCommandId),
      profileId: profileId,
      reminderId: ReminderId(_reminderId),
      ownerType: ReminderOwnerType.task,
      ownerId: _widgetTargetId,
      action: ReminderAction.dismiss(),
    );
    if (result is Failed<ReminderActionResult>) {
      fail('notification action failed: ${result.failure.code}');
    }
    final CommittedCommandResult committed =
        (result as Success<ReminderActionResult>).value.committed;
    return _committedIdentity('notify', committed);
  }

  // --- 4. Widget action (R-WIDGET-003) ------------------------------------

  Future<_Committed> deliverWidgetAction() async {
    final Result<CommittedCommandResult> result = await widgetBridge.execute(
      widgetIntent,
    );
    return _fromCommandResult('widget', result);
  }

  // --- shared committed-result normalization ------------------------------

  _Committed _fromCommandResult(
    String tag,
    Result<CommittedCommandResult> result,
  ) {
    if (result is Failed<CommittedCommandResult>) {
      fail('$tag command failed: ${result.failure.code}');
    }
    return _committedIdentity(
      tag,
      (result as Success<CommittedCommandResult>).value,
    );
  }

  _Committed _committedIdentity(String tag, CommittedCommandResult committed) {
    final String identity =
        '$tag|${committed.resultCode}|${committed.payloadVersion}|'
        '${committed.resultPayload}|${committed.commitSeq}';
    return _Committed(identity: identity, freshCommit: !committed.replayed);
  }

  // --- exactly-once effect assertions -------------------------------------

  Future<void> expectExactlyOnceEffects({String describe = ''}) async {
    final String prefix = describe.isEmpty ? '' : '$describe: ';
    expect(
      await directReceiptCount(),
      1,
      reason: '${prefix}direct command receipt not exactly-once',
    );
    expect(
      await directActivityCount(),
      1,
      reason: '${prefix}direct command activity not exactly-once',
    );
    expect(
      await appliedOperationCount(),
      1,
      reason: '${prefix}sync applied-operation not exactly-once',
    );
    expect(
      await syncEntityCount(),
      1,
      reason: '${prefix}sync applier effect not exactly-once',
    );
    expect(
      await notificationReceiptCount(),
      1,
      reason: '${prefix}notification action receipt not exactly-once',
    );
    expect(
      await notificationActivityCount(),
      1,
      reason: '${prefix}notification action activity not exactly-once',
    );
    expect(
      await widgetReceiptCount(),
      1,
      reason: '${prefix}widget action receipt not exactly-once',
    );
    expect(
      await widgetActivityCount(),
      1,
      reason: '${prefix}widget action activity not exactly-once',
    );
  }

  Future<int> directReceiptCount() =>
      _count('command_receipts', 'command_id = ?', <Object?>[_directCommandId]);

  Future<int> directActivityCount() =>
      _count('activity_events', 'id = ?', <Object?>[_directActivityId]);

  Future<int> appliedOperationCount() =>
      _count('applied_operations', 'change_id = ?', <Object?>[_syncChangeId]);

  Future<int> syncEntityCount() =>
      _count('tags', 'id = ?', <Object?>[_syncEntityId]);

  Future<int> notificationReceiptCount() => _count(
    'command_receipts',
    'command_id = ?',
    <Object?>[_notifyActionCommandId],
  );

  Future<int> notificationActivityCount() => _count(
    'activity_events',
    "entity_id = ? AND event_type = 'reminder_dismissed'",
    <Object?>[_reminderId],
  );

  Future<int> widgetReceiptCount() => _count(
    'command_receipts',
    'command_id = ?',
    <Object?>['widget-$_widgetIntentId'],
  );

  Future<int> widgetActivityCount() =>
      _count('activity_events', 'entity_id = ?', <Object?>[_widgetTargetId]);

  Future<int> _count(String table, String where, List<Object?> args) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM $table WHERE $where',
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  Future<SyncCursor> _readCursor() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT epoch, server_seq, cursor FROM sync_cursors '
          'WHERE profile_id = ? AND backend = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(_backend),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return SyncCursor.initial();
    }
    final Map<String, Object?> row = rows.single.data;
    return SyncCursor(
      epoch: SnapshotEpoch(row['epoch'] as int),
      serverSeq: ServerSeq((row['server_seq'] as int?) ?? 0),
      opaqueToken: row['cursor'] as String?,
    );
  }
}

/// A widget command handler that runs the verified command through the real
/// command bus, deriving a stable command id from the intent so a re-delivered
/// intent replays the stored receipt (R-WIDGET-003, R-GEN-005).
final class _BusWidgetCommandHandler implements WidgetCommandHandler {
  _BusWidgetCommandHandler(this.bus, this.profileId);

  final ForgeCommandBus bus;
  final ProfileId profileId;

  @override
  bool supports(WidgetIntentAction action) => true;

  @override
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command) {
    final DurableCommand durable = DurableCommand(
      profileId: profileId,
      commandId: CommandId(command.derivedCommandId),
      commandType: 'widget.${command.action.wireName}',
      schemaVersion: 1,
      requestHash: command.canonicalPayload,
      canonicalPayload: command.canonicalPayload,
    );
    return bus.execute(
      durable,
      (TransactionSession session) async => SemanticWrite(
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

/// An idempotent typed applier for `tag` entities. It upserts the row so
/// re-applying the same change never duplicates it (data-model §6).
final class _TagApplier implements RemoteApplier {
  _TagApplier(this.db, this.profileId);

  final ForgeSchemaDatabase db;
  final ProfileId profileId;

  @override
  String get entityType => 'tag';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (change.tombstone || change.kind == SyncOperationKind.delete) {
      await db.customStatement(
        'DELETE FROM tags WHERE id = ? AND profile_id = ?',
        <Object?>[change.entityId, profileId.value],
      );
      return;
    }
    final String name = change.payload['normalized_name'] as String;
    final String display = (change.payload['display_name'] as String?) ?? name;
    await db.customStatement(
      'INSERT INTO tags '
      '(id, profile_id, normalized_name, display_name, created_at_utc, '
      'updated_at_utc) VALUES (?, ?, ?, ?, 0, 0) '
      'ON CONFLICT(id) DO UPDATE SET normalized_name = excluded.normalized_name,'
      ' display_name = excluded.display_name, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[change.entityId, profileId.value, name, display],
    );
  }
}
