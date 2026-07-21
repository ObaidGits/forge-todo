import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/domain/study_session_event_kind.dart';

/// Explicit mapping between the learning Drift rows and immutable domain
/// aggregates (design.md "Data Models").
abstract final class LearningMapper {
  // ---- courses / Learning Resources --------------------------------------

  static LearningResource resourceFromRow(CourseRow row) => LearningResource(
    id: LearningResourceId(row.id),
    profileId: ProfileId(row.profileId),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    title: row.title,
    type: LearningResourceType.fromWire(row.resourceType),
    status: LearningResourceStatus.fromWire(row.status),
    progressMode: LearningProgressMode.fromWire(row.progressMode),
    sourceUri: row.sourceUri,
    creator: row.creator,
    noteId: row.noteId,
    manualProgressPermille: row.manualProgressPermille,
    rank: row.rank,
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static CoursesCompanion resourceToInsert(LearningResource resource) =>
      CoursesCompanion.insert(
        id: resource.id.value,
        profileId: resource.profileId.value,
        lifeAreaId: resource.lifeAreaId.value,
        title: resource.title,
        resourceType: resource.type.wire,
        sourceUri: Value<String?>(resource.sourceUri),
        creator: Value<String?>(resource.creator),
        status: resource.status.wire,
        progressMode: resource.progressMode.wire,
        manualProgressPermille: Value<int?>(resource.manualProgressPermille),
        noteId: Value<String?>(resource.noteId),
        rank: resource.rank,
        revision: Value<int>(resource.revision),
        createdAtUtc: resource.createdAtUtc,
        updatedAtUtc: resource.updatedAtUtc,
        deletedAtUtc: Value<int?>(resource.deletedAtUtc),
      );

  static CoursesCompanion resourceToUpdate(LearningResource resource) =>
      CoursesCompanion(
        title: Value<String>(resource.title),
        resourceType: Value<String>(resource.type.wire),
        sourceUri: Value<String?>(resource.sourceUri),
        creator: Value<String?>(resource.creator),
        status: Value<String>(resource.status.wire),
        progressMode: Value<String>(resource.progressMode.wire),
        manualProgressPermille: Value<int?>(resource.manualProgressPermille),
        noteId: Value<String?>(resource.noteId),
        revision: Value<int>(resource.revision),
        updatedAtUtc: Value<int>(resource.updatedAtUtc),
        deletedAtUtc: Value<int?>(resource.deletedAtUtc),
      );

  // ---- learning_items -----------------------------------------------------

  static LearningItem itemFromRow(LearningItemRow row) => LearningItem(
    id: row.id,
    profileId: row.profileId,
    courseId: row.courseId,
    parentId: row.parentId,
    title: row.title,
    type: LearningItemType.fromWire(row.itemType),
    sourceUri: row.sourceUri,
    durationSec: row.durationSec,
    completedAtUtc: row.completedAtUtc,
    rank: row.rank,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
  );

  static LearningItemsCompanion itemToInsert(LearningItem item) =>
      LearningItemsCompanion.insert(
        id: item.id,
        profileId: item.profileId,
        courseId: item.courseId,
        parentId: Value<String?>(item.parentId),
        title: item.title,
        itemType: item.type.wire,
        sourceUri: Value<String?>(item.sourceUri),
        durationSec: Value<int?>(item.durationSec),
        completedAtUtc: Value<int?>(item.completedAtUtc),
        rank: item.rank,
        createdAtUtc: item.createdAtUtc,
        updatedAtUtc: item.updatedAtUtc,
      );

  static LearningItemsCompanion itemToUpdate(LearningItem item) =>
      LearningItemsCompanion(
        title: Value<String>(item.title),
        itemType: Value<String>(item.type.wire),
        sourceUri: Value<String?>(item.sourceUri),
        durationSec: Value<int?>(item.durationSec),
        completedAtUtc: Value<int?>(item.completedAtUtc),
        rank: Value<String>(item.rank),
        updatedAtUtc: Value<int>(item.updatedAtUtc),
      );

  // ---- study_sessions -----------------------------------------------------

  static StudySession sessionFromRow(StudySessionRow row) => StudySession(
    id: row.id,
    profileId: row.profileId,
    courseId: row.courseId,
    logicalId: row.logicalId,
    startedAtUtc: row.startedAtUtc,
    endedAtUtc: row.endedAtUtc,
    durationSec: row.durationSec,
    itemId: row.itemId,
    focusSessionId: row.focusSessionId,
    note: row.note,
    version: row.version,
    supersedesId: row.supersedesId,
    isCurrent: row.isCurrent,
    createdAtUtc: row.createdAtUtc,
  );

  static StudySessionsCompanion sessionToInsert(StudySession session) =>
      StudySessionsCompanion.insert(
        id: session.id,
        profileId: session.profileId,
        courseId: session.courseId,
        logicalId: session.logicalId,
        itemId: Value<String?>(session.itemId),
        focusSessionId: Value<String?>(session.focusSessionId),
        startedAtUtc: session.startedAtUtc,
        endedAtUtc: session.endedAtUtc,
        durationSec: session.durationSec,
        note: Value<String?>(session.note),
        version: session.version,
        supersedesId: Value<String?>(session.supersedesId),
        isCurrent: session.isCurrent,
        createdAtUtc: session.createdAtUtc,
      );

  // ---- study_session_events ----------------------------------------------

  static StudySessionEvent eventFromRow(StudySessionEventRow row) =>
      StudySessionEvent(
        id: row.id,
        profileId: row.profileId,
        sessionId: row.sessionId,
        logicalId: row.logicalId,
        kind: StudySessionEventKind.fromWire(row.eventKind),
        commandId: row.commandId,
        payload: row.payload,
        payloadVersion: row.payloadVersion,
        occurredAtUtc: row.occurredAtUtc,
        supersedesId: row.supersedesId,
      );

  static StudySessionEventsCompanion eventToInsert(StudySessionEvent event) =>
      StudySessionEventsCompanion.insert(
        id: event.id,
        profileId: event.profileId,
        sessionId: event.sessionId,
        logicalId: event.logicalId,
        commandId: Value<String?>(event.commandId),
        eventKind: event.kind.wire,
        payload: Value<String?>(event.payload),
        payloadVersion: event.payloadVersion,
        occurredAtUtc: event.occurredAtUtc,
        supersedesId: Value<String?>(event.supersedesId),
      );
}
