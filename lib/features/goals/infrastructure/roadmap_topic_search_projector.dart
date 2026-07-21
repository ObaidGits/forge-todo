import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/infrastructure/roadmap_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The roadmap-topic search contributor (R-SEARCH-001).
///
/// Roadmap topics are one of the MVP searchable types (R-SEARCH-001). A topic's
/// searchable content is its title; it carries no separate long-form body (its
/// note is a canonical reference indexed by the notes projector). The projector
/// lives in the goals feature because it reads authoritative `roadmap_topics`
/// rows, and depends only on the search feature's exported [SearchProjector]
/// contract. It is registered into the same transactional
/// [SearchProjectionRegistry] as the other contributors, so `search_documents`,
/// the FTS index and the dirty watermark advance atomically with the topic
/// write.
final class RoadmapTopicSearchProjector implements SearchProjector {
  const RoadmapTopicSearchProjector();

  static const String kind = 'roadmap_topic';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final RoadmapWriteRepository repo = session.repositories
        .resolve<RoadmapWriteRepository>();
    final RoadmapTopic? topic = await repo.findTopic(profileId, entityId);
    if (topic == null || topic.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: topic.title,
      body: '',
      sourceRevision: topic.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final RoadmapWriteRepository repo = session.repositories
        .resolve<RoadmapWriteRepository>();
    return repo.activeTopicIds(profileId);
  }
}
