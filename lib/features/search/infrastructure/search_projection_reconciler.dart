import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/repositories/cross_cutting_repositories.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/features/search/domain/search_dirty_key.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';

/// The result of a reconciliation pass.
final class SearchReconcileReport {
  const SearchReconcileReport({
    required this.reconciled,
    required this.failed,
    required this.skipped,
  });

  /// Markers whose document was regenerated and marker cleared.
  final int reconciled;

  /// Markers whose projection threw and were left for retry.
  final int failed;

  /// Markers with no registered projector (unknown type), left in place.
  final int skipped;
}

/// Startup/resume reconciliation for the unified search projection
/// (design.md §5 "reconciled on startup/resume until their projection watermark
/// reaches commit_seq").
///
/// In steady state the command bus maintains the index in-transaction and
/// clears its `search` markers, so a normal pass finds nothing. This reconciler
/// exists for robustness: markers seeded by a rebuild/migration, or left by an
/// older build that predated the in-transaction coordinator, are regenerated
/// from source here. Each marker is processed in its own transaction so a
/// single failing entity does not block the rest.
final class SearchProjectionReconciler {
  SearchProjectionReconciler({
    required this.db,
    required this.unitOfWork,
    required this.registry,
    required this.clock,
  });

  final ForgeSchemaDatabase db;
  final UnitOfWork unitOfWork;
  final SearchProjectionRegistry registry;
  final Clock clock;

  Future<SearchReconcileReport> reconcile(String profileId) async {
    final List<QueryRow> markers = await db
        .customSelect(
          'SELECT projection_key, source_commit_seq FROM projection_dirty '
          "WHERE profile_id = ? AND projection = '${SearchDirtyKey.projection}' "
          'ORDER BY source_commit_seq ASC',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();

    int reconciled = 0;
    int failed = 0;
    int skipped = 0;

    for (final QueryRow marker in markers) {
      final String key = marker.data['projection_key'] as String;
      final int sourceSeq = marker.data['source_commit_seq'] as int;
      final SearchDirtyRef? ref = SearchDirtyKey.decode(key);
      if (ref == null || registry.projectorFor(ref.entityType) == null) {
        skipped += 1;
        continue;
      }
      final bool ok = await _reconcileOne(profileId, ref, key, sourceSeq);
      if (ok) {
        reconciled += 1;
      } else {
        failed += 1;
      }
    }

    return SearchReconcileReport(
      reconciled: reconciled,
      failed: failed,
      skipped: skipped,
    );
  }

  Future<bool> _reconcileOne(
    String profileId,
    SearchDirtyRef ref,
    String key,
    int sourceSeq,
  ) async {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    try {
      await unitOfWork.transaction<void>((TransactionSession session) async {
        await registry.projectEntity(
          session: session,
          profileId: profileId,
          entityType: ref.entityType,
          entityId: ref.entityId,
          nowUtc: now,
        );
        await session.repositories.resolve<ProjectionDirtyRepository>().clear(
          profileId: profileId,
          projection: SearchDirtyKey.projection,
          projectionKey: key,
          reconciledCommitSeq: sourceSeq,
        );
      });
      return true;
    } on Object catch (error) {
      await _recordFailure(profileId, key, error.toString(), now);
      return false;
    }
  }

  Future<void> _recordFailure(
    String profileId,
    String key,
    String error,
    int now,
  ) async {
    await unitOfWork.transaction<void>((TransactionSession session) async {
      await session.repositories
          .resolve<ProjectionDirtyRepository>()
          .recordFailure(
            profileId: profileId,
            projection: SearchDirtyKey.projection,
            projectionKey: key,
            error: error,
            updatedAtUtc: now,
          );
    });
  }
}
