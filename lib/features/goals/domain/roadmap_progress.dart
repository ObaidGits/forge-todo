import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';

/// Pure roadmap progress policy (R-GOAL-004). No persistence, no double count.
///
/// Derived roadmap progress uses **only roadmap topics** as weighted leaves.
/// This policy is a thin, deliberate adapter over the shared
/// [GoalProgressPolicy.derived]: every topic is projected onto a single
/// [GoalProgressLeaf] through [RoadmapTopic.toProgressLeaf], so milestones,
/// checklist items, and linked tasks/notes/resources can never contribute
/// independently — the only way anything counts is by being a topic
/// (R-GOAL-004). Because both the overall roadmap progress and each section's
/// presentation aggregation flow through the *same* policy, a topic is counted
/// once and only once.
abstract final class RoadmapProgressPolicy {
  /// The derived progress for a whole roadmap from all its [topics]
  /// (R-GOAL-004). Ineligible (archived/cancelled/deleted) topics are excluded;
  /// completed topics contribute their null-normalized nonnegative weight; a
  /// zero eligible total yields "not started / no computable progress".
  static GoalProgress forRoadmap(Iterable<RoadmapTopic> topics) =>
      GoalProgressPolicy.derived(
        topics.map((RoadmapTopic t) => t.toProgressLeaf()),
      );

  /// The **presentation-only** aggregation for one section from its direct
  /// [sectionTopics] (R-GOAL-004). Sections carry no completion weight of their
  /// own in V1; this simply aggregates the section's eligible descendant topic
  /// weights using the identical derived formula, so it can never diverge from
  /// or double-count against the roadmap total.
  static GoalProgress forSection(Iterable<RoadmapTopic> sectionTopics) =>
      GoalProgressPolicy.derived(
        sectionTopics.map((RoadmapTopic t) => t.toProgressLeaf()),
      );
}
