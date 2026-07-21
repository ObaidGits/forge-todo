import 'dart:convert';

import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';

/// A projection-dirty marker a pull page must record for [PullApplyCoordinator].
final class DirtyProjectionMarker {
  const DirtyProjectionMarker({
    required this.projection,
    required this.projectionKey,
  });

  final String projection;
  final String projectionKey;
}

/// The full unit of work one pull page applies: the translated, cursor-decided
/// page, the durable conflict artifacts it delivers, and the projection-dirty
/// markers its effects invalidate. Every element commits together with the
/// cursor advance, or none do (Property 4).
final class PullApplyRequest {
  const PullApplyRequest({
    required this.page,
    this.backend = 'supabase',
    this.conflicts = const <ConflictArtifact>[],
    this.dirtyProjections = const <DirtyProjectionMarker>[],
  });

  final TranslatedPullPage page;
  final String backend;
  final List<ConflictArtifact> conflicts;
  final List<DirtyProjectionMarker> dirtyProjections;
}

/// The outcome of attempting to apply one pull page.
enum PullApplyOutcome {
  /// The page was contiguous and applied; the cursor advanced.
  applied,

  /// The page was already applied (a duplicate); nothing changed.
  duplicate,

  /// A gap, expired cursor, or epoch mismatch: apply was refused and a verified
  /// bootstrap is required. Nothing changed.
  bootstrapRequired,
}

/// The result of [PullApplyCoordinator.applyPage].
final class PullApplyResult {
  const PullApplyResult({
    required this.outcome,
    required this.appliedChangeCount,
    required this.cursor,
  });

  final PullApplyOutcome outcome;
  final int appliedChangeCount;

  /// The cursor after this page: the advanced cursor on [PullApplyOutcome.applied],
  /// otherwise the caller's incoming cursor unchanged.
  final SyncCursor cursor;
}

/// The named phase boundaries of a pull-apply transaction, used only to inject
/// faults in tests. Production code never passes a fault hook.
enum PullApplyPhase {
  /// Before the transaction is opened.
  beforeTransaction,

  /// After every feature applier has run, before applied-operation records.
  afterAppliers,

  /// After applied-operation records, before durable conflicts.
  afterAppliedOperations,

  /// After durable conflicts, before projection-dirty markers.
  afterConflicts,

  /// After projection-dirty markers, before the cursor advance.
  afterDirtyMarkers,

  /// After the cursor advance, before the transaction commits.
  afterCursorAdvance,
}

/// A test-only hook invoked at each [PullApplyPhase]; throwing simulates a crash
/// at that phase.
typedef PullApplyFault = Future<void> Function(PullApplyPhase phase);

/// Applies one ordered, translated pull page atomically (data-model.md §6
/// "Pull", design.md §8, R-SYNC-003/R-SYNC-004/NFR-REL-002).
///
/// Within one local transaction (`WriteOrigin.remoteApply`) the coordinator:
///
/// 1. routes each change to its owning typed applier, parent-before-child;
/// 2. records an idempotent applied-operation marker per change;
/// 3. writes every durable conflict artifact the page delivered;
/// 4. writes every projection-dirty marker the effects invalidated;
/// 5. advances the local pull cursor.
///
/// All five happen in the same transaction, so an unexpected failure at any
/// point leaves the cursor unadvanced and no partial rows — old-or-new, never
/// partial. Re-pulling a page the cursor has already passed is a harmless
/// no-op, and re-applying is idempotent because appliers are idempotent and the
/// applied-operation/conflict/dirty writes upsert.
final class PullApplyCoordinator {
  PullApplyCoordinator({
    required this.unitOfWork,
    required this.appliers,
    required this.clock,
    this.fault,
  });

  final UnitOfWork unitOfWork;
  final RemoteApplierRegistry appliers;
  final Clock clock;

  /// Test-only fault hook. Null in production.
  final PullApplyFault? fault;

  Future<void> _fireFault(PullApplyPhase phase) async {
    final PullApplyFault? hook = fault;
    if (hook != null) {
      await hook(phase);
    }
  }

  /// Applies [request] and returns the outcome. Throws if a feature applier or
  /// a write fails (or a fault is injected): the enclosing transaction rolls
  /// back wholly, leaving the cursor and all rows exactly as before.
  Future<PullApplyResult> applyPage(PullApplyRequest request) async {
    final TranslatedPullPage page = request.page;
    final SyncCursor incoming = page.page.nextCursor;

    switch (page.decision) {
      case CursorAdvanceDecision.duplicate:
        return PullApplyResult(
          outcome: PullApplyOutcome.duplicate,
          appliedChangeCount: 0,
          cursor: incoming,
        );
      case CursorAdvanceDecision.bootstrap:
        return PullApplyResult(
          outcome: PullApplyOutcome.bootstrapRequired,
          appliedChangeCount: 0,
          cursor: incoming,
        );
      case CursorAdvanceDecision.apply:
        break;
    }

    final String profileId = page.localProfileId.value;
    final String backend = request.backend;
    final int now = clock.utcNow().microsecondsSinceEpoch;
    final int epoch = page.page.epoch.value;

    await _fireFault(PullApplyPhase.beforeTransaction);

    await unitOfWork.transaction<void>((TransactionSession session) async {
      // Phase 1 — typed applier effects, parent-before-child.
      await appliers.applyAll(session, page.changes);
      await _fireFault(PullApplyPhase.afterAppliers);

      // Phase 2 — idempotent applied-operation records.
      final AppliedOperationRepository appliedRepo = session.repositories
          .resolve<AppliedOperationRepository>();
      for (final RemoteChange change in page.changes) {
        await appliedRepo.record(
          profileId: profileId,
          backend: backend,
          operationId: change.changeId,
          changeId: change.changeId,
          checksum: _checksum(change),
          appliedAtUtc: now,
          epoch: epoch,
        );
      }
      await _fireFault(PullApplyPhase.afterAppliedOperations);

      // Phase 3 — durable conflict artifacts.
      final SyncConflictRepository conflictRepo = session.repositories
          .resolve<SyncConflictRepository>();
      for (final ConflictArtifact artifact in request.conflicts) {
        await conflictRepo.upsertArtifact(
          profileId: profileId,
          id: artifact.remoteArtifactId,
          artifact: artifact,
        );
      }
      await _fireFault(PullApplyPhase.afterConflicts);

      // Phase 4 — projection-dirty markers.
      final ProjectionDirtyRepository dirtyRepo = session.repositories
          .resolve<ProjectionDirtyRepository>();
      for (final DirtyProjectionMarker marker in request.dirtyProjections) {
        await dirtyRepo.mark(
          profileId: profileId,
          projection: marker.projection,
          projectionKey: marker.projectionKey,
          sourceCommitSeq: session.commitSeq,
          updatedAtUtc: now,
        );
      }
      await _fireFault(PullApplyPhase.afterDirtyMarkers);

      // Phase 5 — advance the ordered pull cursor.
      final SyncCursorRepository cursorRepo = session.repositories
          .resolve<SyncCursorRepository>();
      await cursorRepo.save(
        profileId: profileId,
        backend: backend,
        cursor: incoming,
        updatedAtUtc: now,
      );
      await _fireFault(PullApplyPhase.afterCursorAdvance);
    }, origin: WriteOrigin.remoteApply);

    return PullApplyResult(
      outcome: PullApplyOutcome.applied,
      appliedChangeCount: page.changes.length,
      cursor: incoming,
    );
  }

  /// A deterministic content checksum for the applied-operation record. Uses a
  /// stable FNV-1a hash over the change's canonical shape so the same change
  /// always hashes identically across runs and devices (no random/clock input).
  static String _checksum(RemoteChange change) {
    final String canonical = jsonEncode(<String, Object?>{
      'entityType': change.entityType,
      'entityId': change.entityId,
      'kind': change.kind.wire,
      'serverVersion': change.serverVersion,
      'tombstone': change.tombstone,
      'payload': change.payload,
    });
    return _fnv1a(canonical);
  }

  static String _fnv1a(String input) {
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    int hash = offsetBasis;
    for (final int unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
