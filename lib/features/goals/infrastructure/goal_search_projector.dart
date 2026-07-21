import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/infrastructure/goal_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The goal search contributor (R-SEARCH-001).
///
/// A goal's searchable content is its title (primary rank field) plus its
/// outcome statement as the body. The projector lives in the goals feature
/// because it reads authoritative `goals` rows, and depends only on the search
/// feature's exported [SearchProjector] contract. It is registered into the
/// same transactional [SearchProjectionRegistry] as the task and note
/// contributors, so `search_documents`, the FTS index and the dirty watermark
/// advance atomically with the goal write.
final class GoalSearchProjector implements SearchProjector {
  const GoalSearchProjector();

  static const String kind = 'goal';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    final Goal? goal = await repo.find(profileId, entityId);
    if (goal == null || goal.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: goal.title,
      // The outcome statement is plain prose; it is indexed at the lower body
      // weight (design.md §14 `title > body`).
      body: goal.outcomeMd,
      sourceRevision: goal.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final GoalWriteRepository repo = session.repositories
        .resolve<GoalWriteRepository>();
    return repo.activeIds(profileId);
  }
}
