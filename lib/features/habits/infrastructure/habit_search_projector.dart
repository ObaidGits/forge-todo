import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/habits/domain/habit.dart';
import 'package:forge/features/habits/infrastructure/habit_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The habit search contributor (R-SEARCH-001, R-HABIT-001).
///
/// A habit's searchable content is its title (the sole ranked field); schedule
/// cadence, target kind, and status are structured facets handled by the habit
/// read model rather than free text. The projector lives in the habits feature
/// because it reads the authoritative `habits` rows, and depends only on the
/// search feature's exported [SearchProjector] contract. It is registered into
/// the same transactional [SearchProjectionRegistry] as the task/note/goal/
/// learning contributors so `search_documents`, the FTS index, and the dirty
/// watermark advance atomically with the habit write.
final class HabitSearchProjector implements SearchProjector {
  const HabitSearchProjector();

  /// The stable entity-type discriminator used in `search` dirty keys.
  static const String kind = 'habit';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    final Habit? habit = await repo.findHabit(profileId, entityId);
    if (habit == null || habit.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: habit.title,
      // Habits carry no free-text body; the title is the sole ranked field.
      body: '',
      sourceRevision: habit.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final HabitWriteRepository repo = session.repositories
        .resolve<HabitWriteRepository>();
    return repo.activeHabitIds(profileId);
  }
}
