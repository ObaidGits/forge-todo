import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/search/domain/search_document.dart';

/// A typed search contributor for one entity type (design.md §14, R-SEARCH-001).
///
/// Every release-present searchable type (MVP: task, note, roadmap topic, goal,
/// Learning Resource/item, habit) registers exactly one projector. A projector
/// derives a [SearchDocumentDraft] from the authoritative source rows inside the
/// SAME transaction as the domain write, so the domain row, `search_documents`,
/// the `search_fts` index and the dirty watermark advance atomically. The
/// projector never opens its own transaction; it reads through the
/// transaction-scoped [RepositorySet] on the supplied [TransactionSession].
///
/// This is an application contract: implementations live in the feature that
/// owns the entity's source rows (for example the tasks feature owns the task
/// projector) and depend only on this exported contract, never on the search
/// feature's infrastructure.
abstract interface class SearchProjector {
  /// The stable entity-type discriminator, e.g. `task`. Matches the type
  /// segment of a `search` dirty projection key.
  String get entityType;

  /// Builds the searchable document for [entityId] within [session], or returns
  /// `null` when the entity does not exist for [profileId] or has been
  /// tombstoned/soft-deleted (its document is removed/hidden transactionally).
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  );

  /// Enumerates every current (non-tombstoned) source entity id for [profileId].
  /// Used by the source rebuild path to regenerate `search_documents` entirely
  /// from source rows after a migration or index rebuild.
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  );
}
