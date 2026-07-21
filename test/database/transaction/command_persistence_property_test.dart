import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';

import '../../helpers/fake_clock.dart';
import '../schema/schema_test_database.dart';

/// Property 1: Durable command persistence (design.md).
///
/// > A durable command reported as successful exists after process restart and
/// > returns the same receipt on replay.
///
/// This is a generative/property-based test. For each generated case it builds
/// a randomized sequence of durable commands (mixing sync-eligible and
/// local-only commands, fresh executions, in-session replays, and hash
/// conflicts), executes them against a **file-backed** Drift store, then
/// simulates a process restart by closing and reopening the command bus over
/// the *same persisted file*. It asserts that every command the bus reported as
/// successful still has its durable receipt after restart, that replaying it
/// returns a byte-identical stored receipt, and that no replay produces a
/// duplicated effect in any cross-cutting table.
///
/// **Validates: Requirements R-GEN-001, R-GEN-005**
void main() {
  // A solid number of generated cases with per-case randomized sequences.
  const int caseCount = 60;
  const int baseSeed = 0x50C1A; // stable, reproducible base seed.

  test(
    '[TEST-DB-CMD-DURABLE-RESTART][MVP][TASK-3.8][R-GEN-001,R-GEN-005] '
    'a durable command reported successful persists across process restart '
    'and replay returns the identical receipt with no duplicated effects',
    () async {
      for (int caseIndex = 0; caseIndex < caseCount; caseIndex += 1) {
        final int seed = baseSeed + caseIndex;
        await _runOneCase(seed);
      }
    },
    // Real file I/O plus many reopen cycles; keep generous headroom.
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _runOneCase(int seed) async {
  final Random rng = Random(seed);
  final Directory dir = Directory.systemTemp.createTempSync('forge_cmd_pbt_');
  final String storePath = '${dir.path}/store.sqlite';

  // The set of distinct commands this case will attempt.
  final List<_GenCommand> plan = _generatePlan(rng);

  // The execution schedule: distinct commands interleaved with in-session
  // replays of already-issued commands (same id + same hash).
  final List<_ScheduledExecution> schedule = _generateSchedule(rng, plan);

  // Records the stable committed result of the FIRST successful execution of
  // each command id. This is the receipt the restart+replay must reproduce.
  final Map<String, CommittedCommandResult> expected =
      <String, CommittedCommandResult>{};

  _RestartableBus bus = await _RestartableBus.open(
    storePath,
    freshProfile: true,
  );
  try {
    for (final _ScheduledExecution step in schedule) {
      final _GenCommand spec = step.command;
      final Result<CommittedCommandResult> result = await bus.bus.execute(
        spec.toDurable(),
        (TransactionSession session) async => spec.toWrite(),
        origin: WriteOrigin.localCommand,
      );

      final CommittedCommandResult? value = result.valueOrNull;
      if (value == null) {
        // The only expected failure is a deliberate hash-conflict replay, which
        // must never be reported as success and must never mint a receipt.
        expect(
          result.failureOrNull?.kind,
          FailureKind.conflict,
          reason:
              'seed=$seed unexpected failure for ${spec.id}: '
              '${result.failureOrNull?.code}',
        );
        expect(
          step.expectConflict,
          isTrue,
          reason: 'seed=$seed command ${spec.id} failed unexpectedly',
        );
        continue;
      }

      // A successful, non-replayed execution is the authoritative first commit.
      if (!expected.containsKey(spec.id)) {
        expect(
          value.replayed,
          isFalse,
          reason: 'seed=$seed first success for ${spec.id} must be a commit',
        );
        expected[spec.id] = value;
      } else {
        // In-session replay: must return the already-stored receipt verbatim.
        expect(value.replayed, isTrue, reason: 'seed=$seed ${spec.id} replay');
        _expectSameReceipt(expected[spec.id]!, value, seed, spec.id);
      }
    }

    // Capture the durable footprint immediately before the simulated restart.
    final _TableCounts before = await bus.tableCounts();

    // Every successful command must have exactly one durable receipt.
    expect(
      before.receipts,
      expected.length,
      reason: 'seed=$seed receipt count must equal distinct successes',
    );

    // --- Simulate process restart: close everything, reopen the same file. ---
    await bus.close();
    bus = await _RestartableBus.open(storePath, freshProfile: false);

    // Persistence survived the restart: the store still holds all the rows.
    final _TableCounts afterRestart = await bus.tableCounts();
    expect(
      afterRestart,
      before,
      reason: 'seed=$seed durable state changed across restart',
    );

    // For every command reported successful, the receipt must exist and replay
    // must return the identical stored result.
    for (final MapEntry<String, CommittedCommandResult> entry
        in expected.entries) {
      final String id = entry.key;
      final CommittedCommandResult original = entry.value;
      final _GenCommand spec = plan.firstWhere((_GenCommand c) => c.id == id);

      // 1) The durable receipt still exists after restart.
      final Map<String, Object?>? row = await bus.receiptRow(id);
      expect(
        row,
        isNotNull,
        reason: 'seed=$seed receipt for $id missing after restart',
      );
      expect(row!['request_hash'], spec.requestHash);
      expect(row['result_code'], original.resultCode);
      expect(row['payload_version'], original.payloadVersion);
      expect(row['commit_seq'], original.commitSeq);

      // 2) Replaying the command returns the identical stored receipt.
      final Result<CommittedCommandResult> replay = await bus.bus.execute(
        spec.toDurable(),
        (TransactionSession session) async =>
            fail('seed=$seed body must not run on post-restart replay of $id'),
      );
      final CommittedCommandResult replayed = replay.valueOrNull!;
      expect(
        replayed.replayed,
        isTrue,
        reason: 'seed=$seed $id must replay, not re-commit',
      );
      _expectSameReceipt(original, replayed, seed, id);
    }

    // 3) No replay produced any duplicated effect anywhere.
    final _TableCounts afterReplay = await bus.tableCounts();
    expect(
      afterReplay,
      afterRestart,
      reason: 'seed=$seed replay duplicated durable effects',
    );
  } finally {
    await bus.close();
    dir.deleteSync(recursive: true);
  }
}

void _expectSameReceipt(
  CommittedCommandResult a,
  CommittedCommandResult b,
  int seed,
  String id,
) {
  expect(b.resultCode, a.resultCode, reason: 'seed=$seed $id resultCode');
  expect(b.resultPayload, a.resultPayload, reason: 'seed=$seed $id payload');
  expect(
    b.payloadVersion,
    a.payloadVersion,
    reason: 'seed=$seed $id payloadVersion',
  );
  expect(b.commitSeq, a.commitSeq, reason: 'seed=$seed $id commitSeq');
}

// --- Generators ------------------------------------------------------------

const List<String> _resultCodes = <String>['ok', 'created', 'updated'];

/// Generates a set of distinct durable commands with randomized attributes.
List<_GenCommand> _generatePlan(Random rng) {
  final int count = 1 + rng.nextInt(12);
  return <_GenCommand>[
    for (int i = 0; i < count; i += 1)
      _GenCommand(
        index: i,
        id: 'cmd-$i',
        requestHash: 'h${rng.nextInt(1 << 30)}-$i',
        resultCode: _resultCodes[rng.nextInt(_resultCodes.length)],
        payloadVersion: 1 + rng.nextInt(3),
        resultPayload: rng.nextBool()
            ? null
            : '{"e":"e$i","v":${rng.nextInt(99)}}',
        syncEligible: rng.nextBool(),
      ),
  ];
}

/// Builds the execution schedule: each distinct command appears at least once,
/// then a random selection are replayed in-session (same id, same hash), and a
/// random selection are also issued with a *different* hash to prove a hash
/// conflict is rejected and never reported as success.
List<_ScheduledExecution> _generateSchedule(
  Random rng,
  List<_GenCommand> plan,
) {
  final List<_ScheduledExecution> schedule = <_ScheduledExecution>[];
  for (final _GenCommand command in plan) {
    schedule.add(_ScheduledExecution(command: command));
    // Optional in-session replay with the SAME hash.
    if (rng.nextBool()) {
      schedule.add(_ScheduledExecution(command: command));
    }
    // Optional hash-conflict attempt (different hash under the same id).
    if (rng.nextInt(4) == 0) {
      schedule.add(
        _ScheduledExecution(
          command: command.withHash('${command.requestHash}-CONFLICT'),
          expectConflict: true,
        ),
      );
    }
  }
  // Shuffle while keeping each command's first (creating) execution before its
  // replays/conflicts, so the schedule stays valid.
  return _stableInterleave(rng, schedule, plan);
}

/// Interleaves executions randomly but guarantees the first execution of each
/// command id precedes any of its replays/conflicts.
List<_ScheduledExecution> _stableInterleave(
  Random rng,
  List<_ScheduledExecution> schedule,
  List<_GenCommand> plan,
) {
  // Bucket by id preserving relative order, then merge randomly.
  final Map<String, List<_ScheduledExecution>> byId =
      <String, List<_ScheduledExecution>>{};
  for (final _ScheduledExecution step in schedule) {
    byId.putIfAbsent(step.command.id, () => <_ScheduledExecution>[]).add(step);
  }
  final List<List<_ScheduledExecution>> queues = byId.values.toList();
  final List<_ScheduledExecution> merged = <_ScheduledExecution>[];
  while (queues.any((List<_ScheduledExecution> q) => q.isNotEmpty)) {
    final List<List<_ScheduledExecution>> nonEmpty = queues
        .where((List<_ScheduledExecution> q) => q.isNotEmpty)
        .toList();
    final List<_ScheduledExecution> pick =
        nonEmpty[rng.nextInt(nonEmpty.length)];
    merged.add(pick.removeAt(0));
  }
  return merged;
}

final class _GenCommand {
  const _GenCommand({
    required this.index,
    required this.id,
    required this.requestHash,
    required this.resultCode,
    required this.payloadVersion,
    required this.resultPayload,
    required this.syncEligible,
  });

  final int index;
  final String id;
  final String requestHash;
  final String resultCode;
  final int payloadVersion;
  final String? resultPayload;
  final bool syncEligible;

  _GenCommand withHash(String hash) => _GenCommand(
    index: index,
    id: id,
    requestHash: hash,
    resultCode: resultCode,
    payloadVersion: payloadVersion,
    resultPayload: resultPayload,
    syncEligible: syncEligible,
  );

  DurableCommand toDurable() => DurableCommand(
    profileId: ProfileId('profile-1'),
    commandId: CommandId(id),
    commandType: 'task.create',
    schemaVersion: 1,
    requestHash: requestHash,
    canonicalPayload: '{"intent":"create","i":$index}',
  );

  SemanticWrite toWrite() => SemanticWrite(
    resultCode: resultCode,
    payloadVersion: payloadVersion,
    resultPayload: resultPayload,
    activity: <ActivityDraft>[
      ActivityDraft(
        id: 'act-$index',
        eventType: 'created',
        entityType: 'task',
        entityId: 'e$index',
        payloadVersion: 1,
      ),
    ],
    dirtyProjections: <DirtyProjectionDraft>[
      DirtyProjectionDraft(projection: 'search', projectionKey: 'e$index'),
    ],
    outboxGroup: syncEligible
        ? OutboxGroupDraft(
            groupId: 'grp-$index',
            snapshotEpoch: 1,
            operations: <OutboxOperationDraft>[
              OutboxOperationDraft(
                operationId: 'op-$index',
                entityType: 'task',
                entityId: 'e$index',
                opKind: 'insert',
                payload: '{"title":"t$index"}',
              ),
            ],
          )
        : null,
  );
}

final class _ScheduledExecution {
  const _ScheduledExecution({
    required this.command,
    this.expectConflict = false,
  });

  final _GenCommand command;
  final bool expectConflict;
}

// --- File-backed, reopenable command bus -----------------------------------

/// A command bus stack bound to a real, reopenable file-backed Drift store.
///
/// [close] releases the SQLite connection (flushing to disk) and [open] against
/// the same [storePath] reconstructs the whole stack, which is what makes the
/// "process restart" in this property genuine rather than an in-memory illusion.
final class _RestartableBus {
  _RestartableBus._(this._db, this.bus);

  final ForgeSchemaDatabase _db;
  final ForgeCommandBus bus;

  static Future<_RestartableBus> open(
    String storePath, {
    required bool freshProfile,
  }) async {
    final ForgeSchemaDatabase db = ForgeSchemaDatabase(
      NativeDatabase(File(storePath)),
    );
    if (freshProfile) {
      await insertProfile(db);
    }
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => 'profile-1',
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: FakeClock(initialUtc: DateTime.utc(2024, 1, 1)),
    );
    return _RestartableBus._(db, bus);
  }

  Future<void> close() => _db.close();

  Future<int> _count(String table) async {
    final List<QueryRow> rows = await _db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .get();
    return rows.single.data['n'] as int;
  }

  Future<_TableCounts> tableCounts() async => _TableCounts(
    receipts: await _count('command_receipts'),
    commitLog: await _count('commit_log'),
    activity: await _count('activity_events'),
    dirty: await _count('projection_dirty'),
    outbox: await _count('outbox_mutations'),
    journal: await _count('pending_command_journal'),
  );

  Future<Map<String, Object?>?> receiptRow(String commandId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT request_hash, result_code, payload_version, commit_seq '
          'FROM command_receipts WHERE command_id = ?',
          variables: <Variable<Object>>[Variable<Object>(commandId)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }
}

final class _TableCounts {
  const _TableCounts({
    required this.receipts,
    required this.commitLog,
    required this.activity,
    required this.dirty,
    required this.outbox,
    required this.journal,
  });

  final int receipts;
  final int commitLog;
  final int activity;
  final int dirty;
  final int outbox;
  final int journal;

  @override
  bool operator ==(Object other) =>
      other is _TableCounts &&
      other.receipts == receipts &&
      other.commitLog == commitLog &&
      other.activity == activity &&
      other.dirty == dirty &&
      other.outbox == outbox &&
      other.journal == journal;

  @override
  int get hashCode =>
      Object.hash(receipts, commitLog, activity, dirty, outbox, journal);

  @override
  String toString() =>
      'receipts=$receipts commitLog=$commitLog activity=$activity '
      'dirty=$dirty outbox=$outbox journal=$journal';
}
