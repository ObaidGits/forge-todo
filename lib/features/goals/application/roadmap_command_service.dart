import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart'
    show MoveInput;
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

/// The durable roadmap command surface (R-GOAL-003, R-GOAL-004, R-GOAL-005,
/// R-GEN-005). Every method commits one atomic transaction through the command
/// bus and returns the stable committed result, never a dispatch
/// acknowledgement.
///
/// [commandId] makes each call idempotent: replaying the same id with the same
/// request returns the stored result; a different request under the same id is
/// rejected as a conflict.
abstract interface class RoadmapCommandService {
  // ---- roadmap ------------------------------------------------------------

  /// Creates the goal's single roadmap (R-GOAL-001, R-GOAL-003). Fails if the
  /// goal already owns a roadmap. The result payload carries the roadmap id.
  Future<Result<CommittedCommandResult>> createRoadmap({
    required CommandId commandId,
    required ProfileId profileId,
    required GoalId goalId,
    required CreateRoadmapInput input,
  });

  /// Patches a roadmap's descriptive fields (R-GOAL-003).
  Future<Result<CommittedCommandResult>> updateRoadmap({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
    required UpdateRoadmapInput input,
  });

  // ---- sections -----------------------------------------------------------

  /// Adds an ordered section to a roadmap (R-GOAL-003, R-GOAL-005).
  Future<Result<CommittedCommandResult>> addSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
    required CreateSectionInput input,
  });

  /// Patches a section (R-GOAL-003).
  Future<Result<CommittedCommandResult>> updateSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required UpdateSectionInput input,
  });

  /// Reorders a section among its siblings (R-GOAL-005).
  Future<Result<CommittedCommandResult>> moveSection({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required MoveInput input,
  });

  /// Rebalances all section ranks in a roadmap to fresh, evenly-spaced values
  /// as one sync-safe semantic group (R-GOAL-005).
  Future<Result<CommittedCommandResult>> rebalanceSections({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapId roadmapId,
  });

  // ---- topics -------------------------------------------------------------

  /// Adds an ordered topic to a section (R-GOAL-003, R-GOAL-004, R-GOAL-005).
  Future<Result<CommittedCommandResult>> addTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
    required CreateTopicInput input,
  });

  /// Patches a topic's descriptive fields, including its completion weight
  /// (R-GOAL-003, R-GOAL-004).
  Future<Result<CommittedCommandResult>> updateTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required UpdateTopicInput input,
  });

  /// Sets a topic's status, recording/clearing the completion instant
  /// (R-GOAL-004).
  Future<Result<CommittedCommandResult>> setTopicStatus({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required RoadmapTopicStatus status,
  });

  /// Reorders a topic within its section (R-GOAL-005).
  Future<Result<CommittedCommandResult>> moveTopic({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required MoveInput input,
  });

  /// Rebalances all topic ranks in a section as one sync-safe semantic group
  /// (R-GOAL-005).
  Future<Result<CommittedCommandResult>> rebalanceTopics({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapSectionId sectionId,
  });

  /// Links a topic to a task/note/Learning Resource through `entity_links`
  /// (R-GOAL-003). Cross-profile targets are rejected (R-GEN-002).
  Future<Result<CommittedCommandResult>> linkTopicEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required LinkTopicEntityInput input,
  });

  /// Removes a topic link (R-GOAL-003).
  Future<Result<CommittedCommandResult>> unlinkTopicEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required LinkTopicEntityInput input,
  });

  // ---- checklist items ----------------------------------------------------

  /// Adds an ordered checklist item to a topic (R-GOAL-003, R-GOAL-005).
  Future<Result<CommittedCommandResult>> addChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required RoadmapTopicId topicId,
    required CreateChecklistItemInput input,
  });

  /// Patches a checklist item (R-GOAL-003).
  Future<Result<CommittedCommandResult>> updateChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required UpdateChecklistItemInput input,
  });

  /// Checks or unchecks a checklist item (R-GOAL-003).
  Future<Result<CommittedCommandResult>> setChecklistItemChecked({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required bool checked,
  });

  /// Reorders a checklist item within its topic (R-GOAL-005).
  Future<Result<CommittedCommandResult>> moveChecklistItem({
    required CommandId commandId,
    required ProfileId profileId,
    required ChecklistItemId itemId,
    required MoveInput input,
  });
}
