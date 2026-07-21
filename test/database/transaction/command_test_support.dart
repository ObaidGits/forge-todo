import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/sync/acknowledgement_service.dart';
import 'package:forge/app/infrastructure/database/sync/journal_maintenance.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/fake_clock.dart';
import '../schema/schema_test_database.dart';

/// Wiring for transaction / command-bus tests over a real in-memory schema DB.
final class CommandHarness {
  CommandHarness._(
    this.db,
    this.profileId,
    this.clock,
    this.unitOfWork,
    this.bus,
    this.acknowledgements,
    this.maintenance,
    this.hintHandler,
  );

  static Future<CommandHarness> open({
    DateTime? initialUtc,
    List<AfterCommitHandler> handlers = const <AfterCommitHandler>[],
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 1, 1),
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
    );
    final RecordingHintHandler recorder = RecordingHintHandler();
    final AfterCommitDispatcher dispatcher = AfterCommitDispatcher(
      handlers: <AfterCommitHandler>[recorder, ...handlers],
    );
    return CommandHarness._(
      db,
      ProfileId(profileId),
      clock,
      unitOfWork,
      ForgeCommandBus(
        unitOfWork: unitOfWork,
        clock: clock,
        afterCommit: dispatcher,
      ),
      SyncAcknowledgementService(unitOfWork: unitOfWork, clock: clock),
      JournalMaintenance(unitOfWork: unitOfWork, clock: clock),
      recorder,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final FakeClock clock;
  final DriftUnitOfWork unitOfWork;
  final ForgeCommandBus bus;
  final SyncAcknowledgementService acknowledgements;
  final JournalMaintenance maintenance;
  final RecordingHintHandler hintHandler;

  Future<void> close() => db.close();

  Future<int> rowCount(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(sql, variables: _vars(args))
        .get();
    return rows.length;
  }

  Future<int> scalarInt(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(sql, variables: _vars(args))
        .get();
    return rows.single.data['n'] as int;
  }

  Future<Map<String, Object?>?> firstRow(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(sql, variables: _vars(args))
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return rows.first.data;
  }
}

List<Variable<Object>> _vars(List<Object?> args) => <Variable<Object>>[
  for (final Object? a in args) Variable<Object>(a as Object),
];

/// A durable command builder with sensible defaults.
DurableCommand command({
  required ProfileId profileId,
  required String id,
  String requestHash = 'hash-1',
  String type = 'task.create',
  String payload = '{"intent":"create"}',
  Map<String, int>? baseVersions,
}) => DurableCommand(
  profileId: profileId,
  commandId: CommandId(id),
  commandType: type,
  schemaVersion: 1,
  requestHash: requestHash,
  canonicalPayload: payload,
  baseVersions: baseVersions,
);

/// A semantic write producing one activity, one dirty projection, and an
/// optional single-operation outbox group.
SemanticWrite semanticWrite({
  String resultCode = 'ok',
  int payloadVersion = 1,
  String? resultPayload = '{"id":"e1"}',
  String activityId = 'act-1',
  String entityId = 'e1',
  String projection = 'search',
  bool syncEligible = true,
  String groupId = 'grp-1',
  String operationId = 'op-1',
  List<AfterCommitHint> hints = const <AfterCommitHint>[],
}) => SemanticWrite(
  resultCode: resultCode,
  payloadVersion: payloadVersion,
  resultPayload: resultPayload,
  activity: <ActivityDraft>[
    ActivityDraft(
      id: activityId,
      eventType: 'created',
      entityType: 'task',
      entityId: entityId,
      payloadVersion: 1,
    ),
  ],
  dirtyProjections: <DirtyProjectionDraft>[
    DirtyProjectionDraft(projection: projection, projectionKey: entityId),
  ],
  outboxGroup: syncEligible
      ? OutboxGroupDraft(
          groupId: groupId,
          snapshotEpoch: 1,
          operations: <OutboxOperationDraft>[
            OutboxOperationDraft(
              operationId: operationId,
              entityType: 'task',
              entityId: entityId,
              opKind: 'insert',
              payload: '{"title":"t"}',
            ),
          ],
        )
      : null,
  afterCommitHints: hints,
);

/// Records dispatched hints for idempotence assertions.
final class RecordingHintHandler implements AfterCommitHandler {
  final List<AfterCommitHint> received = <AfterCommitHint>[];

  @override
  Set<String> get kinds => <String>{'projection', 'reminder'};

  @override
  Future<void> handle(AfterCommitHint hint) async {
    received.add(hint);
  }
}

/// A handler that always throws, to prove hint failures are swallowed.
final class ThrowingHintHandler implements AfterCommitHandler {
  bool called = false;

  @override
  Set<String> get kinds => <String>{'projection'};

  @override
  Future<void> handle(AfterCommitHint hint) async {
    called = true;
    throw StateError('handler boom');
  }
}
