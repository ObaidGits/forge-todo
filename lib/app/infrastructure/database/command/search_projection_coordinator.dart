import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';

/// In-transaction maintenance hook for the unified search projection.
///
/// The command bus invokes the coordinator inside the semantic write, passing
/// the `search` dirty projection markers the command body emitted. The
/// coordinator maintains `search_documents` and the `search_fts` index in the
/// SAME transaction so the domain row and its search rows commit atomically
/// (design.md §14, data-model §4), and advances/clears the search watermark it
/// handled. The bus depends on this narrow interface, never on the search
/// feature's infrastructure (design.md §16 fitness rule).
abstract interface class SearchProjectionCoordinator {
  /// Maintains the search index for every `search` marker in [searchMarkers],
  /// running inside the active [session] transaction. [nowUtc] is the commit
  /// timestamp used for document rows.
  Future<void> maintain(
    TransactionSession session,
    String profileId,
    List<DirtyProjectionDraft> searchMarkers,
    int nowUtc,
  );
}
