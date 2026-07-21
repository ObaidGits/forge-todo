import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/core/domain/result.dart';

import '../../helpers/evidence.dart';
import '../schema/schema_test_database.dart';
import 'command_test_support.dart';

/// Property 2 — Atomic semantic writes.
///
/// A failed semantic transaction leaves no partial domain, authoritative
/// FTS/search-dirty, activity, dirty-marker, pending-command journal,
/// command-receipt, or outbox state, while a subsequent successful command
/// still commits atomically over the same real Drift database.
///
/// This is a generative/property test: it randomizes the shape of a
/// sync-eligible semantic write and the point at which the transaction fails
/// (before any write, after partial in-body writes, and at the commit boundary
/// via injected constraint violations), then asserts the post-failure state is
/// byte-for-byte identical to the pre-failure snapshot and that forward
/// atomicity is preserved.
///
/// **Validates: Requirements R-GEN-005, R-NOTE-004, R-SYNC-002, NFR-REL-002**
EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-TXN-ATOMIC-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.9'),
  requirements: <RequirementId>[
    RequirementId('R-GEN-005'),
    RequirementId('R-NOTE-004'),
    RequirementId('R-SYNC-002'),
    RequirementId('NFR-REL-002'),
  ],
);

/// The randomized point at which a transaction is made to fail.
enum _FailureMode {
  /// The command body throws before writing anything.
  earlyThrow,

  /// The body writes a real domain row plus partial cross-cutting rows and
  /// then throws — proving in-body partial writes roll back.
  midBodyThrow,

  /// The body writes a real domain row and returns a semantic write whose
  /// activity list collides on its primary key, failing inside the bus
  /// persistence step after the commit log and receipt are already written.
  duplicateActivityAtPersist,

  /// The body writes a real domain row and returns a semantic write whose
  /// outbox group repeats an operation id, failing at the deepest point of
  /// the commit boundary (after commit log, receipt, activity, and dirty).
  duplicateOutboxOpAtPersist,

  /// The body inserts a domain row whose unique key collides with an already
  /// committed row, failing on the domain write itself.
  collideExistingDomain,
}

/// Table counts that together represent every write class named by Property 2.
typedef _StateSnapshot = Map<String, int>;

void main() {
  const int caseCount = 240;

  group('given a real Drift database and randomized failing semantic '
      'writes', () {
    testWithEvidence(
      _evidence('001'),
      'a failed transaction at any generated boundary leaves no partial '
      'domain, search, activity, dirty, journal, receipt, or outbox state '
      'and a later command still commits atomically',
      () async {
        for (int seed = 0; seed < caseCount; seed += 1) {
          await _runCase(seed);
        }
      },
    );
  });
}

Future<void> _runCase(int seed) async {
  final Random rng = Random(seed);
  final _FailureMode mode =
      _FailureMode.values[rng.nextInt(_FailureMode.values.length)];
  final CommandHarness h = await CommandHarness.open();
  final String describe = 'seed=$seed mode=${mode.name}';
  try {
    // Optionally seed unrelated, already-committed state to prove a failure
    // never disturbs pre-existing durable rows.
    if (rng.nextBool()) {
      await _commitOk(h, 'base-$seed');
    }

    // The row that collideExistingDomain will conflict with.
    String? collidingTagName;
    if (mode == _FailureMode.collideExistingDomain) {
      collidingTagName = 'dup-$seed';
      await _commitOk(h, 'collide-src-$seed', tagName: collidingTagName);
    }

    final _StateSnapshot before = await _snapshot(h);

    final bool threw = await _runFailingCommand(
      h,
      seed,
      mode,
      rng,
      collidingTagName,
    );
    expect(
      threw,
      isTrue,
      reason: '$describe: the failing command was expected to throw',
    );

    // Property 2: the failed transaction left no partial state of any class.
    final _StateSnapshot after = await _snapshot(h);
    expect(
      after,
      before,
      reason: '$describe: a failed transaction left partial state behind',
    );

    // Forward atomicity: a subsequent successful command still commits every
    // write class together over the same database.
    await _commitOk(h, 'ok-$seed', tagName: 'ok-tag-$seed');
    final _StateSnapshot done = await _snapshot(h);
    for (final MapEntry<String, int> entry in before.entries) {
      expect(
        done[entry.key],
        entry.value + 1,
        reason:
            '$describe: forward commit did not atomically add one '
            '${entry.key} row',
      );
    }
  } finally {
    await h.close();
  }
}

/// Executes a command engineered to fail per [mode]; returns whether it threw.
Future<bool> _runFailingCommand(
  CommandHarness h,
  int seed,
  _FailureMode mode,
  Random rng,
  String? collidingTagName,
) async {
  final String commandId = 'fail-$seed';
  final String entityId = 'e-fail-$seed-${rng.nextInt(1 << 20)}';
  final String failTagId = 'tag-fail-$seed';

  Future<void> execute() {
    switch (mode) {
      case _FailureMode.earlyThrow:
        return h.bus
            .execute(
              command(profileId: h.profileId, id: commandId),
              (_) async => throw StateError('fail-early'),
            )
            .then(_throwIfFailure);

      case _FailureMode.midBodyThrow:
        return h.bus
            .execute(command(profileId: h.profileId, id: commandId), (
              session,
            ) async {
              await insertTag(
                h.db,
                h.profileId.value,
                id: failTagId,
                normalizedName: 'mid-$seed',
              );
              await session.repositories.resolve<ActivityRepository>().append(
                id: 'act-fail-$seed',
                profileId: h.profileId.value,
                eventType: 'created',
                entityType: 'task',
                entityId: entityId,
                occurredAtUtc: 0,
                payloadVersion: 1,
                commitSeq: session.commitSeq,
              );
              await session.repositories
                  .resolve<ProjectionDirtyRepository>()
                  .mark(
                    profileId: h.profileId.value,
                    projection: 'search',
                    projectionKey: entityId,
                    sourceCommitSeq: session.commitSeq,
                    updatedAtUtc: 0,
                  );
              throw StateError('fail-mid');
            })
            .then(_throwIfFailure);

      case _FailureMode.duplicateActivityAtPersist:
        return h.bus
            .execute(command(profileId: h.profileId, id: commandId), (_) async {
              await insertTag(
                h.db,
                h.profileId.value,
                id: failTagId,
                normalizedName: 'dupact-$seed',
              );
              return SemanticWrite(
                resultCode: 'ok',
                payloadVersion: 1,
                activity: <ActivityDraft>[
                  ActivityDraft(
                    id: 'dup-act-$seed',
                    eventType: 'created',
                    entityType: 'task',
                    entityId: entityId,
                    payloadVersion: 1,
                  ),
                  ActivityDraft(
                    id: 'dup-act-$seed', // duplicate primary key
                    eventType: 'created',
                    entityType: 'task',
                    entityId: entityId,
                    payloadVersion: 1,
                  ),
                ],
                dirtyProjections: <DirtyProjectionDraft>[
                  DirtyProjectionDraft(
                    projection: 'search',
                    projectionKey: entityId,
                  ),
                ],
              );
            })
            .then(_throwIfFailure);

      case _FailureMode.duplicateOutboxOpAtPersist:
        return h.bus
            .execute(command(profileId: h.profileId, id: commandId), (_) async {
              await insertTag(
                h.db,
                h.profileId.value,
                id: failTagId,
                normalizedName: 'dupop-$seed',
              );
              return SemanticWrite(
                resultCode: 'ok',
                payloadVersion: 1,
                activity: <ActivityDraft>[
                  ActivityDraft(
                    id: 'act-op-$seed',
                    eventType: 'created',
                    entityType: 'task',
                    entityId: entityId,
                    payloadVersion: 1,
                  ),
                ],
                dirtyProjections: <DirtyProjectionDraft>[
                  DirtyProjectionDraft(
                    projection: 'search',
                    projectionKey: entityId,
                  ),
                ],
                outboxGroup: OutboxGroupDraft(
                  groupId: 'grp-fail-$seed',
                  snapshotEpoch: 1,
                  operations: <OutboxOperationDraft>[
                    OutboxOperationDraft(
                      operationId: 'op-dup-$seed',
                      entityType: 'task',
                      entityId: entityId,
                      opKind: 'insert',
                      payload: '{"title":"t"}',
                    ),
                    OutboxOperationDraft(
                      operationId: 'op-dup-$seed', // duplicate primary key
                      entityType: 'task',
                      entityId: entityId,
                      opKind: 'patch',
                      payload: '{"title":"t2"}',
                    ),
                  ],
                ),
              );
            })
            .then(_throwIfFailure);

      case _FailureMode.collideExistingDomain:
        return h.bus
            .execute(command(profileId: h.profileId, id: commandId), (_) async {
              // Same (profile_id, normalized_name) as an already-committed tag
              // violates the partial unique index ux_tags_name.
              await insertTag(
                h.db,
                h.profileId.value,
                id: failTagId,
                normalizedName: collidingTagName!,
              );
              return semanticWrite(entityId: entityId);
            })
            .then(_throwIfFailure);
    }
  }

  try {
    await execute();
    return false;
  } on Object {
    return true;
  }
}

/// Commits a fully-formed, sync-eligible semantic write that also persists one
/// real domain row, so the success path proves atomic creation of every class.
Future<void> _commitOk(CommandHarness h, String key, {String? tagName}) async {
  final Result<CommittedCommandResult> result = await h.bus.execute(
    command(profileId: h.profileId, id: 'cmd-$key', requestHash: 'h-$key'),
    (_) async {
      await insertTag(
        h.db,
        h.profileId.value,
        id: 'tag-$key',
        normalizedName: tagName ?? 'name-$key',
      );
      return semanticWrite(
        entityId: 'e-$key',
        activityId: 'a-$key',
        groupId: 'g-$key',
        operationId: 'op-$key',
      );
    },
  );
  expect(
    result.valueOrNull,
    isNotNull,
    reason: 'setup/forward command cmd-$key must commit',
  );
}

/// Counts every write class named by Property 2, including the domain table
/// (`tags`) and the authoritative-search dirty markers specifically.
Future<_StateSnapshot> _snapshot(CommandHarness h) async {
  return <String, int>{
    'domain_tags': await h.scalarInt('SELECT COUNT(*) AS n FROM tags'),
    'activity': await h.scalarInt('SELECT COUNT(*) AS n FROM activity_events'),
    'dirty': await h.scalarInt('SELECT COUNT(*) AS n FROM projection_dirty'),
    'search_dirty': await h.scalarInt(
      "SELECT COUNT(*) AS n FROM projection_dirty WHERE projection = 'search'",
    ),
    'journal': await h.scalarInt(
      'SELECT COUNT(*) AS n FROM pending_command_journal',
    ),
    'receipts': await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
    'outbox': await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
    'commit_log': await h.scalarInt('SELECT COUNT(*) AS n FROM commit_log'),
  };
}

/// Turns a mapped [Failure] result into a thrown error so every failure mode —
/// whether it throws directly or returns a failed [Result] — is treated as a
/// failed transaction by the caller.
void _throwIfFailure(Result<CommittedCommandResult> result) {
  final Failure? failure = result.failureOrNull;
  if (failure != null) {
    throw StateError('command failed: ${failure.code}');
  }
}
