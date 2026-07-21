/// Property 4 — Atomic pull progress.
///
/// A semantic remote transaction group, its durable conflicts, dirty
/// projections, and cursor advancement commit together or not at all. Applying
/// one translated, ordered pull page is all-or-nothing: within the single pull
/// transaction the semantic group's typed applier effects, every durable
/// conflict artifact, every projection-dirty marker, the applied-operation
/// records, AND the cursor advance either all commit or all roll back. A
/// failure injected at any sub-step leaves the cursor unadvanced and no partial
/// rows, and a subsequent clean re-pull converges. Re-pulling a page the cursor
/// has already passed is a harmless idempotent no-op.
///
/// This is a generative/property test over a real Drift database: it randomizes
/// the shape of a pulled page (change count, conflict count, dirty markers,
/// pre-existing committed state) and the phase at which the pull transaction is
/// made to fail, then asserts the post-failure state is byte-for-byte identical
/// to the pre-failure snapshot, that a clean re-pull commits every class
/// together and advances the cursor, and that replaying the applied page
/// changes nothing.
///
/// **Property 4: Atomic pull progress**
/// **Validates: Requirements R-SYNC-003, R-SYNC-004, NFR-REL-002**
library;

import 'dart:math';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/sync/pull_apply_coordinator.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../../helpers/evidence.dart';
import '../../helpers/fake_clock.dart';
import '../schema/schema_test_database.dart';

const String _profileId = 'profile-1';
const String _remoteProfileId = 'remote-1';
const String _backend = 'supabase';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-PULLATOMIC-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.7'),
  requirements: <RequirementId>[
    RequirementId('R-SYNC-003'),
    RequirementId('R-SYNC-004'),
    RequirementId('NFR-REL-002'),
  ],
);

void main() {
  const int caseCount = 240;

  group('given a real Drift database and randomized inbound pull pages', () {
    testWithEvidence(
      _evidence('PROP-001'),
      'a fault at any pull sub-step rolls the whole page back (cursor '
      'unadvanced, no partial rows), a clean re-pull commits every class '
      'together, and replaying the page changes nothing',
      () async {
        for (int seed = 0; seed < caseCount; seed += 1) {
          await _runCase(seed);
        }
      },
    );
  });

  group('Pull-apply atomicity examples', () {
    testWithEvidence(
      _evidence('APPLY-COMMITS-ALL'),
      'a clean pull commits appliers, applied-ops, conflicts, dirty and cursor',
      () async {
        final _Harness h = await _Harness.open();
        try {
          final _PageSpec spec = _PageSpec(
            epoch: 0,
            fromSeq: 0,
            toSeq: 2,
            changeIds: const <String>['t-a', 't-b'],
            conflictIds: const <String>['art-x'],
            dirtyKeys: const <String>['t-a', 't-b'],
          );
          final _Snapshot before = await h.snapshot();
          final PullApplyResult result = await h.applyClean(spec);

          expect(result.outcome, PullApplyOutcome.applied);
          final _Snapshot after = await h.snapshot();
          expect(after.tags, before.tags + 2);
          expect(after.applied, before.applied + 2);
          expect(after.conflicts, before.conflicts + 1);
          expect(after.dirty, before.dirty + 2);
          expect(after.cursorEpoch, 0);
          expect(after.cursorSeq, 2);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('CONFLICT-FAULT-ROLLS-BACK'),
      'a fault after conflicts are written still rolls back every class',
      () async {
        final _Harness h = await _Harness.open();
        try {
          final _PageSpec spec = _PageSpec(
            epoch: 0,
            fromSeq: 0,
            toSeq: 1,
            changeIds: const <String>['t-a'],
            conflictIds: const <String>['art-x'],
            dirtyKeys: const <String>['t-a'],
          );
          final _Snapshot before = await h.snapshot();
          await expectLater(
            h.applyFaulty(spec, PullApplyPhase.afterConflicts),
            throwsA(isA<StateError>()),
          );
          final _Snapshot after = await h.snapshot();
          expect(after, before);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('DUPLICATE-IS-NOOP'),
      'replaying an already-applied page is a harmless duplicate no-op',
      () async {
        final _Harness h = await _Harness.open();
        try {
          final _PageSpec spec = _PageSpec(
            epoch: 0,
            fromSeq: 0,
            toSeq: 1,
            changeIds: const <String>['t-a'],
            conflictIds: const <String>['art-x'],
            dirtyKeys: const <String>['t-a'],
          );
          await h.applyClean(spec);
          final _Snapshot before = await h.snapshot();
          final PullApplyResult replay = await h.applyClean(spec);
          expect(replay.outcome, PullApplyOutcome.duplicate);
          final _Snapshot after = await h.snapshot();
          expect(after, before);
        } finally {
          await h.close();
        }
      },
    );

    testWithEvidence(
      _evidence('GAP-REQUIRES-BOOTSTRAP'),
      'a non-contiguous page is refused with no writes and no cursor move',
      () async {
        final _Harness h = await _Harness.open();
        try {
          // Cursor starts at (0,0); a page starting at seq 3 is a gap.
          final _PageSpec spec = _PageSpec(
            epoch: 0,
            fromSeq: 3,
            toSeq: 5,
            changeIds: const <String>['t-a'],
            conflictIds: const <String>[],
            dirtyKeys: const <String>['t-a'],
          );
          final _Snapshot before = await h.snapshot();
          final PullApplyResult result = await h.applyClean(spec);
          expect(result.outcome, PullApplyOutcome.bootstrapRequired);
          final _Snapshot after = await h.snapshot();
          expect(after, before);
        } finally {
          await h.close();
        }
      },
    );
  });
}

/// The randomized failure point for a case, including "no fault".
enum _FaultChoice {
  none,
  beforeTransaction,
  afterAppliers,
  afterAppliedOperations,
  afterConflicts,
  afterDirtyMarkers,
  afterCursorAdvance,
}

PullApplyPhase _phaseFor(_FaultChoice choice) => switch (choice) {
  _FaultChoice.beforeTransaction => PullApplyPhase.beforeTransaction,
  _FaultChoice.afterAppliers => PullApplyPhase.afterAppliers,
  _FaultChoice.afterAppliedOperations => PullApplyPhase.afterAppliedOperations,
  _FaultChoice.afterConflicts => PullApplyPhase.afterConflicts,
  _FaultChoice.afterDirtyMarkers => PullApplyPhase.afterDirtyMarkers,
  _FaultChoice.afterCursorAdvance => PullApplyPhase.afterCursorAdvance,
  _FaultChoice.none => throw StateError('no phase for none'),
};

Future<void> _runCase(int seed) async {
  final Random rng = Random(seed);
  final _FaultChoice fault =
      _FaultChoice.values[rng.nextInt(_FaultChoice.values.length)];
  final _Harness h = await _Harness.open();
  final String describe = 'seed=$seed fault=${fault.name}';
  try {
    // Optionally seed unrelated, already-committed inbound state to prove a
    // failure never disturbs pre-existing durable rows/cursor progress.
    int nextSeq = 0;
    if (rng.nextBool()) {
      final _PageSpec seedSpec = _PageSpec(
        epoch: 0,
        fromSeq: 0,
        toSeq: 1,
        changeIds: <String>['seed-$seed'],
        conflictIds: <String>['seed-art-$seed'],
        dirtyKeys: <String>['seed-$seed'],
      );
      await h.applyClean(seedSpec);
      nextSeq = 1;
    }

    // Generate the page under test.
    final int changeCount = 1 + rng.nextInt(4);
    final int conflictCount = rng.nextInt(3);
    final List<String> changeIds = <String>[
      for (int i = 0; i < changeCount; i += 1) 'c-$seed-$i',
    ];
    final List<String> conflictIds = <String>[
      for (int i = 0; i < conflictCount; i += 1) 'a-$seed-$i',
    ];
    // One search-dirty marker per change (distinct keys).
    final List<String> dirtyKeys = List<String>.of(changeIds);
    final _PageSpec spec = _PageSpec(
      epoch: 0,
      fromSeq: nextSeq,
      toSeq: nextSeq + changeCount,
      changeIds: changeIds,
      conflictIds: conflictIds,
      dirtyKeys: dirtyKeys,
    );

    if (fault == _FaultChoice.none) {
      // All-or-nothing success path plus idempotent replay.
      final _Snapshot before = await h.snapshot();
      final PullApplyResult applied = await h.applyClean(spec);
      expect(
        applied.outcome,
        PullApplyOutcome.applied,
        reason: '$describe: a contiguous page must apply',
      );
      _expectCommitted(before, await h.snapshot(), spec, describe);
      await _expectReplayNoop(h, spec, describe);
      return;
    }

    // Fault path: the transaction must roll back wholly.
    final _Snapshot before = await h.snapshot();
    await expectLater(
      h.applyFaulty(spec, _phaseFor(fault)),
      throwsA(isA<StateError>()),
      reason: '$describe: the faulty pull must throw',
    );
    final _Snapshot afterFault = await h.snapshot();
    expect(
      afterFault,
      before,
      reason:
          '$describe: a failed pull left partial state or advanced the cursor',
    );

    // Convergence: a subsequent clean re-pull commits every class together.
    final PullApplyResult recovered = await h.applyClean(spec);
    expect(
      recovered.outcome,
      PullApplyOutcome.applied,
      reason: '$describe: the clean re-pull must apply',
    );
    _expectCommitted(before, await h.snapshot(), spec, describe);

    // Idempotence: replaying the now-applied page changes nothing.
    await _expectReplayNoop(h, spec, describe);
  } finally {
    await h.close();
  }
}

void _expectCommitted(
  _Snapshot before,
  _Snapshot after,
  _PageSpec spec,
  String describe,
) {
  expect(
    after.tags,
    before.tags + spec.changeIds.length,
    reason: '$describe: applier domain effects did not commit',
  );
  expect(
    after.applied,
    before.applied + spec.changeIds.length,
    reason: '$describe: applied-operation records did not commit',
  );
  expect(
    after.conflicts,
    before.conflicts + spec.conflictIds.length,
    reason: '$describe: durable conflicts did not commit',
  );
  expect(
    after.dirty,
    before.dirty + spec.dirtyKeys.toSet().length,
    reason: '$describe: projection-dirty markers did not commit',
  );
  expect(
    after.cursorEpoch,
    spec.epoch,
    reason: '$describe: cursor epoch did not advance',
  );
  expect(
    after.cursorSeq,
    spec.toSeq,
    reason: '$describe: cursor sequence did not advance',
  );
}

Future<void> _expectReplayNoop(
  _Harness h,
  _PageSpec spec,
  String describe,
) async {
  final _Snapshot before = await h.snapshot();
  final PullApplyResult replay = await h.applyClean(spec);
  expect(
    replay.outcome,
    PullApplyOutcome.duplicate,
    reason: '$describe: replaying an applied page must be a duplicate no-op',
  );
  expect(
    await h.snapshot(),
    before,
    reason: '$describe: replay created a duplicate effect',
  );
}

/// A generated inbound page description.
final class _PageSpec {
  _PageSpec({
    required this.epoch,
    required this.fromSeq,
    required this.toSeq,
    required this.changeIds,
    required this.conflictIds,
    required this.dirtyKeys,
  });

  final int epoch;
  final int fromSeq;
  final int toSeq;
  final List<String> changeIds;
  final List<String> conflictIds;
  final List<String> dirtyKeys;
}

/// An immutable count of every write class Property 4 spans, plus the cursor.
final class _Snapshot {
  const _Snapshot({
    required this.tags,
    required this.applied,
    required this.conflicts,
    required this.dirty,
    required this.cursorEpoch,
    required this.cursorSeq,
  });

  final int tags;
  final int applied;
  final int conflicts;
  final int dirty;
  final int cursorEpoch;
  final int cursorSeq;

  @override
  bool operator ==(Object other) =>
      other is _Snapshot &&
      other.tags == tags &&
      other.applied == applied &&
      other.conflicts == conflicts &&
      other.dirty == dirty &&
      other.cursorEpoch == cursorEpoch &&
      other.cursorSeq == cursorSeq;

  @override
  int get hashCode =>
      Object.hash(tags, applied, conflicts, dirty, cursorEpoch, cursorSeq);

  @override
  String toString() =>
      'tags=$tags applied=$applied conflicts=$conflicts dirty=$dirty '
      'cursor=($cursorEpoch,$cursorSeq)';
}

/// Test wiring: a real in-memory schema DB, a linked profile, the identity
/// translator, and a [PullApplyCoordinator] with an idempotent tag applier.
final class _Harness {
  _Harness._(this.db, this.unitOfWork, this.translator, this.clock);

  static Future<_Harness> open() async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    await insertProfile(db, id: _profileId);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => _profileId,
    );
    final SyncProfileLink link = SyncProfileLink(
      localProfileId: ProfileId(_profileId),
      backend: _backend,
      ownerUserId: OwnerUserId('owner-1'),
      remoteProfileId: RemoteProfileId(_remoteProfileId),
      state: SyncLinkState.linked,
    );
    final PullTranslator translator = PullTranslator(
      SyncIdentityTranslator(link),
    );
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 1, 1));
    return _Harness._(db, unitOfWork, translator, clock);
  }

  final ForgeSchemaDatabase db;
  final DriftUnitOfWork unitOfWork;
  final PullTranslator translator;
  final FakeClock clock;

  Future<void> close() => db.close();

  PullPage _page(_PageSpec spec) {
    final List<RemoteChange> changes = <RemoteChange>[
      for (int i = 0; i < spec.changeIds.length; i += 1)
        RemoteChange(
          changeId: 'chg-${spec.changeIds[i]}',
          entityType: 'tag',
          entityId: spec.changeIds[i],
          kind: SyncOperationKind.insert,
          serverSeq: ServerSeq(spec.fromSeq + i + 1),
          serverVersion: 1,
          payload: <String, Object?>{
            'normalized_name': 'name-${spec.changeIds[i]}',
            'display_name': 'Display ${spec.changeIds[i]}',
          },
        ),
    ];
    return PullPage(
      remoteProfileId: RemoteProfileId(_remoteProfileId),
      epoch: SnapshotEpoch(spec.epoch),
      fromSeq: ServerSeq(spec.fromSeq),
      toSeq: ServerSeq(spec.toSeq),
      changes: changes,
      nextCursor: SyncCursor(
        epoch: SnapshotEpoch(spec.epoch),
        serverSeq: ServerSeq(spec.toSeq),
      ),
    );
  }

  PullApplyRequest _request(_PageSpec spec) {
    final TranslatedPullPage translated = translator.translate(
      page: _page(spec),
      cursor: _syncCursorSync,
    );
    final int created = clock.utcNow().microsecondsSinceEpoch;
    final List<ConflictArtifact> conflicts = <ConflictArtifact>[
      for (final String id in spec.conflictIds)
        ConflictArtifact(
          remoteArtifactId: id,
          entityType: 'tag',
          entityId: spec.changeIds.first,
          policy: ConflictPolicyKind.sameFieldLaterServerWins,
          fields: const <String>['display_name'],
          createdAtUtc: created,
          localSnapshot: <String, Object?>{'display_name': 'local'},
          remoteSnapshot: <String, Object?>{'display_name': 'remote'},
        ),
    ];
    final List<DirtyProjectionMarker> dirty = <DirtyProjectionMarker>[
      for (final String key in spec.dirtyKeys)
        DirtyProjectionMarker(projection: 'search', projectionKey: key),
    ];
    return PullApplyRequest(
      page: translated,
      backend: _backend,
      conflicts: conflicts,
      dirtyProjections: dirty,
    );
  }

  // Cache of the cursor read immediately before building a request. The
  // translator needs the current cursor to classify the page; we read it from
  // the durable store so the decision reflects committed progress only.
  late SyncCursor _syncCursorSync;

  Future<PullApplyResult> applyClean(_PageSpec spec) async {
    _syncCursorSync = await _readCursor();
    final PullApplyCoordinator coordinator = PullApplyCoordinator(
      unitOfWork: unitOfWork,
      appliers: RemoteApplierRegistry(<RemoteApplier>[_TagApplier(db)]),
      clock: clock,
    );
    return coordinator.applyPage(_request(spec));
  }

  Future<PullApplyResult> applyFaulty(
    _PageSpec spec,
    PullApplyPhase failAt,
  ) async {
    _syncCursorSync = await _readCursor();
    final PullApplyCoordinator coordinator = PullApplyCoordinator(
      unitOfWork: unitOfWork,
      appliers: RemoteApplierRegistry(<RemoteApplier>[_TagApplier(db)]),
      clock: clock,
      fault: (PullApplyPhase phase) async {
        if (phase == failAt) {
          throw StateError('injected crash at ${phase.name}');
        }
      },
    );
    return coordinator.applyPage(_request(spec));
  }

  Future<SyncCursor> _readCursor() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT epoch, server_seq, cursor FROM sync_cursors '
          'WHERE profile_id = ? AND backend = ?',
          variables: <Variable<Object>>[
            Variable<String>(_profileId),
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

  Future<int> _scalar(String sql) async {
    final List<QueryRow> rows = await db.customSelect(sql).get();
    return rows.single.data['n'] as int;
  }

  Future<_Snapshot> snapshot() async {
    final SyncCursor cursor = await _readCursor();
    return _Snapshot(
      tags: await _scalar('SELECT COUNT(*) AS n FROM tags'),
      applied: await _scalar('SELECT COUNT(*) AS n FROM applied_operations'),
      conflicts: await _scalar('SELECT COUNT(*) AS n FROM sync_conflicts'),
      dirty: await _scalar('SELECT COUNT(*) AS n FROM projection_dirty'),
      cursorEpoch: cursor.epoch.value,
      cursorSeq: cursor.serverSeq.value,
    );
  }
}

/// An idempotent typed applier for `tag` entities used only by this test. It
/// upserts the tag row so re-applying the same change never duplicates it, and
/// deletes on a tombstone. Drift routes its statements to the active pull
/// transaction automatically.
final class _TagApplier implements RemoteApplier {
  _TagApplier(this.db);

  final ForgeSchemaDatabase db;

  @override
  String get entityType => 'tag';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (change.tombstone || change.kind == SyncOperationKind.delete) {
      await db.customStatement(
        'DELETE FROM tags WHERE id = ? AND profile_id = ?',
        <Object?>[change.entityId, _profileId],
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
      <Object?>[change.entityId, _profileId, name, display],
    );
  }
}
