import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';

/// Read access to a goal's roadmap and its ordered sections/topics/checklist
/// items (R-GOAL-003, R-GOAL-004). Query methods run outside a write
/// transaction and return immutable domain aggregates in stable rank order.
abstract interface class RoadmapRepository {
  /// The single roadmap owned by [goalId], or null when the goal has none
  /// (R-GOAL-001).
  Future<Roadmap?> findByGoal(ProfileId profileId, GoalId goalId);

  Future<Roadmap?> findById(ProfileId profileId, RoadmapId roadmapId);

  /// The non-deleted sections of [roadmapId], ordered by rank (R-GOAL-005).
  Future<List<RoadmapSection>> sectionsOf(
    ProfileId profileId,
    RoadmapId roadmapId,
  );

  /// The non-deleted topics of [sectionId], ordered by rank (R-GOAL-005).
  Future<List<RoadmapTopic>> topicsOfSection(
    ProfileId profileId,
    RoadmapSectionId sectionId,
  );

  /// Every non-deleted topic under [roadmapId] across all its sections, used to
  /// derive roadmap/goal progress (R-GOAL-004).
  Future<List<RoadmapTopic>> topicsOfRoadmap(
    ProfileId profileId,
    RoadmapId roadmapId,
  );

  Future<RoadmapTopic?> findTopic(ProfileId profileId, RoadmapTopicId topicId);

  /// The goal that owns [topicId] through its section→roadmap→goal chain, or
  /// null when the topic does not exist under [profileId]. Used to resolve a
  /// roadmap-topic search hit to its canonical projection route
  /// (`/goals/<goalId>/roadmap`, R-SEARCH-002).
  Future<GoalId?> goalIdOfTopic(ProfileId profileId, RoadmapTopicId topicId);

  /// The non-deleted checklist items of [topicId], ordered by rank.
  Future<List<ChecklistItem>> checklistItemsOf(
    ProfileId profileId,
    RoadmapTopicId topicId,
  );

  /// The derived progress for the goal, computed **only** from its roadmap
  /// topics as weighted leaves (R-GOAL-004). Returns a "no computable progress"
  /// surface when the goal has no roadmap or no eligible topic weight.
  Future<GoalProgress> deriveGoalProgress(ProfileId profileId, GoalId goalId);
}
