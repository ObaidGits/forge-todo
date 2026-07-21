import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/search/application/search_contracts.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/infrastructure/task_write_repository.dart';

/// The task search contributor — the first registered projector for the unified
/// index (R-SEARCH-001, R-TASK-008, R-NOTE-004).
///
/// A task's searchable content is its title; tags/priority/status are structured
/// filters handled by the task read model rather than free text, and the task's
/// note body lives in the canonical note (R-TASK-010) which the note projector
/// will index in its own wave. The projector lives in the tasks feature because
/// it reads the authoritative `tasks` rows, and depends only on the search
/// feature's exported [SearchProjector] contract.
final class TaskSearchProjector implements SearchProjector {
  const TaskSearchProjector();

  static const String kind = 'task';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    final Task? task = await repo.find(profileId, entityId);
    if (task == null || task.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: task.title,
      // Tasks carry no free-text body; canonical note content is indexed by the
      // note projector. An empty body keeps title the sole ranked field.
      body: '',
      sourceRevision: task.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    return repo.activeIds(profileId);
  }
}
