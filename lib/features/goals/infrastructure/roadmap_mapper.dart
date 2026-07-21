import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_status.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

/// Explicit mapping between the roadmap Drift rows and their immutable domain
/// aggregates (design.md "Data Models").
abstract final class RoadmapMapper {
  // ---- roadmap ------------------------------------------------------------

  static Roadmap fromRow(RoadmapRow row) => Roadmap(
    id: RoadmapId(row.id),
    profileId: ProfileId(row.profileId),
    goalId: GoalId(row.goalId),
    title: row.title,
    status: RoadmapStatus.fromWire(row.status),
    targetDate: row.targetDate,
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static RoadmapsCompanion toInsert(Roadmap roadmap) =>
      RoadmapsCompanion.insert(
        id: roadmap.id.value,
        profileId: roadmap.profileId.value,
        goalId: roadmap.goalId.value,
        title: roadmap.title,
        status: roadmap.status.wire,
        targetDate: Value<String?>(roadmap.targetDate),
        revision: Value<int>(roadmap.revision),
        createdAtUtc: roadmap.createdAtUtc,
        updatedAtUtc: roadmap.updatedAtUtc,
        deletedAtUtc: Value<int?>(roadmap.deletedAtUtc),
      );

  static RoadmapsCompanion toUpdate(Roadmap roadmap) => RoadmapsCompanion(
    title: Value<String>(roadmap.title),
    status: Value<String>(roadmap.status.wire),
    targetDate: Value<String?>(roadmap.targetDate),
    revision: Value<int>(roadmap.revision),
    updatedAtUtc: Value<int>(roadmap.updatedAtUtc),
    deletedAtUtc: Value<int?>(roadmap.deletedAtUtc),
  );

  // ---- section ------------------------------------------------------------

  static RoadmapSection sectionFromRow(RoadmapSectionRow row) => RoadmapSection(
    id: RoadmapSectionId(row.id),
    profileId: ProfileId(row.profileId),
    roadmapId: RoadmapId(row.roadmapId),
    title: row.title,
    rank: GoalRank(row.rank),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static RoadmapSectionsCompanion sectionToInsert(RoadmapSection section) =>
      RoadmapSectionsCompanion.insert(
        id: section.id.value,
        profileId: section.profileId.value,
        roadmapId: section.roadmapId.value,
        title: section.title,
        rank: section.rank.value,
        revision: Value<int>(section.revision),
        createdAtUtc: section.createdAtUtc,
        updatedAtUtc: section.updatedAtUtc,
        deletedAtUtc: Value<int?>(section.deletedAtUtc),
      );

  static RoadmapSectionsCompanion sectionToUpdate(RoadmapSection section) =>
      RoadmapSectionsCompanion(
        title: Value<String>(section.title),
        rank: Value<String>(section.rank.value),
        revision: Value<int>(section.revision),
        updatedAtUtc: Value<int>(section.updatedAtUtc),
        deletedAtUtc: Value<int?>(section.deletedAtUtc),
      );

  // ---- topic --------------------------------------------------------------

  static RoadmapTopic topicFromRow(RoadmapTopicRow row) => RoadmapTopic(
    id: RoadmapTopicId(row.id),
    profileId: ProfileId(row.profileId),
    sectionId: RoadmapSectionId(row.sectionId),
    title: row.title,
    status: RoadmapTopicStatus.fromWire(row.status),
    weight: row.weight,
    estimateSec: row.estimateSec,
    noteId: row.noteId == null ? null : NoteId(row.noteId!),
    completedAtUtc: row.completedAtUtc,
    rank: GoalRank(row.rank),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static RoadmapTopicsCompanion topicToInsert(RoadmapTopic topic) =>
      RoadmapTopicsCompanion.insert(
        id: topic.id.value,
        profileId: topic.profileId.value,
        sectionId: topic.sectionId.value,
        title: topic.title,
        status: topic.status.wire,
        weight: Value<double?>(topic.weight?.toDouble()),
        estimateSec: Value<int?>(topic.estimateSec),
        noteId: Value<String?>(topic.noteId?.value),
        completedAtUtc: Value<int?>(topic.completedAtUtc),
        rank: topic.rank.value,
        revision: Value<int>(topic.revision),
        createdAtUtc: topic.createdAtUtc,
        updatedAtUtc: topic.updatedAtUtc,
        deletedAtUtc: Value<int?>(topic.deletedAtUtc),
      );

  /// A full-row update companion. Every mutable column is written (possibly to
  /// null) so clearing a weight, note, estimate, or completion instant works.
  static RoadmapTopicsCompanion topicToUpdate(RoadmapTopic topic) =>
      RoadmapTopicsCompanion(
        title: Value<String>(topic.title),
        status: Value<String>(topic.status.wire),
        weight: Value<double?>(topic.weight?.toDouble()),
        estimateSec: Value<int?>(topic.estimateSec),
        noteId: Value<String?>(topic.noteId?.value),
        completedAtUtc: Value<int?>(topic.completedAtUtc),
        rank: Value<String>(topic.rank.value),
        revision: Value<int>(topic.revision),
        updatedAtUtc: Value<int>(topic.updatedAtUtc),
        deletedAtUtc: Value<int?>(topic.deletedAtUtc),
      );

  // ---- checklist item -----------------------------------------------------

  static ChecklistItem checklistFromRow(ChecklistItemRow row) => ChecklistItem(
    id: ChecklistItemId(row.id),
    profileId: ProfileId(row.profileId),
    roadmapTopicId: RoadmapTopicId(row.roadmapTopicId),
    text: row.itemText,
    checkedAtUtc: row.checkedAtUtc,
    rank: GoalRank(row.rank),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static ChecklistItemsCompanion checklistToInsert(ChecklistItem item) =>
      ChecklistItemsCompanion.insert(
        id: item.id.value,
        profileId: item.profileId.value,
        roadmapTopicId: item.roadmapTopicId.value,
        itemText: item.text,
        checkedAtUtc: Value<int?>(item.checkedAtUtc),
        rank: item.rank.value,
        revision: Value<int>(item.revision),
        createdAtUtc: item.createdAtUtc,
        updatedAtUtc: item.updatedAtUtc,
        deletedAtUtc: Value<int?>(item.deletedAtUtc),
      );

  static ChecklistItemsCompanion checklistToUpdate(ChecklistItem item) =>
      ChecklistItemsCompanion(
        itemText: Value<String>(item.text),
        checkedAtUtc: Value<int?>(item.checkedAtUtc),
        rank: Value<String>(item.rank.value),
        revision: Value<int>(item.revision),
        updatedAtUtc: Value<int>(item.updatedAtUtc),
        deletedAtUtc: Value<int?>(item.deletedAtUtc),
      );
}
