import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/infrastructure/learning_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The Learning Resource search contributor (R-SEARCH-001, R-LEARN-001).
///
/// A resource's searchable content is its title (primary rank field) plus its
/// creator as lower-weight metadata folded into the body (design.md §14
/// `title > body`). The projector lives in the learning feature because it
/// reads authoritative `courses` rows, and depends only on the search feature's
/// exported [SearchProjector] contract. It is registered into the same
/// transactional [SearchProjectionRegistry] as the task/note contributors so
/// `search_documents`, the FTS index and the dirty watermark advance atomically
/// with the resource write.
final class LearningSearchProjector implements SearchProjector {
  const LearningSearchProjector();

  /// The stable entity-type discriminator. Uses the user-facing concept name
  /// rather than the internal `course` schema name (R-LEARN-001).
  static const String kind = 'learning_resource';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningResource? resource = await repo.findResource(
      profileId,
      entityId,
    );
    if (resource == null || resource.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    final String creator = resource.creator?.trim() ?? '';
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: resource.title,
      body: creator,
      sourceRevision: resource.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    return repo.activeResourceIds(profileId);
  }
}
