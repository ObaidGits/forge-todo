import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/infrastructure/fitness_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The workout search contributor (R-SEARCH-001, R-FIT-001).
///
/// R-SEARCH-001 adds workouts to the unified index in V1. A logged
/// [WorkoutSession] is the canonical, addressable workout record (it opens at
/// `/fitness/<sessionId>` — see `CanonicalRoute`/`CanonicalEntityType.workout`),
/// so the projector indexes sessions rather than reusable templates. A
/// session's searchable content is its title (the sole ranked field); the sets,
/// reps, weights, and durations it owns are structured facets exposed by the
/// fitness read model, never free-text health interpretation (R-FIT-004,
/// R-FIT-005).
///
/// The projector lives in the fitness feature because it reads the
/// authoritative `workout_sessions` rows, and depends only on the search
/// feature's exported [SearchProjector] contract. It is registered into the
/// same transactional [SearchProjectionRegistry] as the task/note/goal/
/// learning/habit contributors so `search_documents`, the FTS index, and the
/// dirty watermark advance atomically with the workout write.
final class WorkoutSearchProjector implements SearchProjector {
  const WorkoutSearchProjector();

  /// The stable entity-type discriminator. Matches
  /// `CanonicalEntityType.workout` so a hit opens the session's canonical
  /// projection at `/fitness/<id>` (R-SEARCH-002).
  static const String kind = 'workout';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    final WorkoutSession? workout = await repo.findSession(profileId, entityId);
    if (workout == null || workout.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: workout.title,
      // Workouts carry no free-text body; the title is the sole ranked field.
      // Set/rep/weight detail stays structured to avoid any health claim.
      body: '',
      sourceRevision: workout.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final FitnessWriteRepository repo = session.repositories
        .resolve<FitnessWriteRepository>();
    return repo.activeSessionIds(profileId);
  }
}
