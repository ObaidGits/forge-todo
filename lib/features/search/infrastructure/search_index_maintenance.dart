import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/features/search/infrastructure/search_fts.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';

/// The outcome of an FTS integrity check.
final class SearchIntegrityReport {
  const SearchIntegrityReport({required this.ok, this.error});

  final bool ok;
  final String? error;
}

/// Migration and rebuild tooling for the unified search index (design.md §14,
/// data-model §4/§5).
///
/// Three operations are provided:
///  * [integrityCheck] verifies the FTS5 index is consistent with its content
///    table using the built-in `integrity-check` command.
///  * [rebuildIndex] rebuilds the FTS5 index from the existing
///    `search_documents` content (fast, index-only) using `rebuild`.
///  * [rebuildFromSources] regenerates `search_documents` and the index
///    entirely from the authoritative source rows through the registered
///    projectors — the migration path when weighting or document shape changes.
final class SearchIndexMaintenance {
  SearchIndexMaintenance({
    required this.db,
    required this.unitOfWork,
    required this.registry,
    required this.clock,
  });

  final ForgeSchemaDatabase db;
  final UnitOfWork unitOfWork;
  final SearchProjectionRegistry registry;
  final Clock clock;

  /// Runs the FTS5 `integrity-check`. Returns a report rather than throwing so
  /// callers can decide whether to trigger a rebuild.
  Future<SearchIntegrityReport> integrityCheck() async {
    try {
      await db.customStatement(
        "INSERT INTO ${SearchFts.table}(${SearchFts.table}) "
        "VALUES ('integrity-check')",
      );
      return const SearchIntegrityReport(ok: true);
    } on Object catch (error) {
      // A corrupt index raises SQLITE_CORRUPT_VTAB; report rather than throw so
      // callers can trigger a rebuild.
      return SearchIntegrityReport(ok: false, error: error.toString());
    }
  }

  /// Rebuilds the FTS5 index from the current `search_documents` content. Fast
  /// path that repairs a corrupt or stale index without touching source rows.
  Future<void> rebuildIndex() async {
    await db.customStatement(
      "INSERT INTO ${SearchFts.table}(${SearchFts.table}) VALUES ('rebuild')",
    );
  }

  /// Regenerates the entire index for [profileId] from source rows in one
  /// transaction. Returns the number of documents regenerated.
  Future<int> rebuildFromSources(String profileId) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    return unitOfWork.transaction<int>(
      (TransactionSession session) =>
          registry.rebuildFromSources(session, profileId, now),
      origin: WriteOrigin.migration,
    );
  }
}
