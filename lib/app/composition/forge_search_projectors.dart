import 'package:forge/features/fitness/infrastructure/workout_search_projector.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
import 'package:forge/features/habits/infrastructure/habit_search_projector.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

/// The canonical set of unified-search projectors, assembled at the composition
/// root (design.md §14, R-SEARCH-001).
///
/// R-SEARCH-001 requires FTS-backed search across every entity type *present in
/// the release*: the MVP indexes tasks, notes, roadmap topics, goals, Learning
/// Resources, and habits; V1 additionally adds workouts once the fitness
/// feature exists (task 10.5). Each type is owned by its feature and
/// contributes exactly one [SearchProjector] from that feature's
/// infrastructure; this list is the single production wiring point so the whole
/// app shares one [SearchProjectionRegistry] rather than forking a second index
/// per surface. Registering the same entity type twice is a wiring error the
/// registry rejects, which the composition test guards against.
///
/// The list is intentionally assembled here in `app` (the only layer allowed to
/// depend on feature infrastructure) so no feature imports another feature's
/// DAO to learn about search (design.md §16).
const List<SearchProjector> forgeMvpSearchProjectors = <SearchProjector>[
  TaskSearchProjector(),
  NoteSearchProjector(),
  GoalSearchProjector(),
  RoadmapTopicSearchProjector(),
  LearningSearchProjector(),
  HabitSearchProjector(),
  // V1: fitness workouts join the same unified index and open at their
  // canonical `/fitness/<id>` projection (R-SEARCH-001, R-FIT-001, task 10.5).
  WorkoutSearchProjector(),
];

/// Builds the production transactional search projector registry from the
/// canonical projector set (R-SEARCH-001). The command bus drives this registry
/// in-transaction so a domain write and its `search_documents`/FTS row advance
/// atomically, and the reconciler/rebuild paths regenerate the index entirely
/// from source rows.
SearchProjectionRegistry buildForgeSearchRegistry() =>
    SearchProjectionRegistry(forgeMvpSearchProjectors);
