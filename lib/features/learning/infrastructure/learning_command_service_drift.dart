import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_command_service.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/edit_sentinel.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_rank.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/domain/study_session_event_kind.dart';
import 'package:forge/features/learning/infrastructure/learning_canonical_request.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/learning/infrastructure/learning_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exceptions raised inside a command body. They roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.code, this.id);
  final String code;
  final String id;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [LearningCommandService]
/// (R-LEARN-001..005, R-FOCUS-005, R-GEN-005).
///
/// Every command commits one atomic transaction with a durable receipt. The
/// study-session lifecycle is immutable: [logStudySession] creates version 1 and
/// [correctStudySession] appends a superseding version plus a `corrected` event,
/// never rewriting prior facts (R-LEARN-002).
final class DriftLearningCommandService implements LearningCommandService {
  DriftLearningCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;
  static const String _resourceEntity = LearningSearchProjector.kind;
  static const String _itemEntity = 'learning_item';
  static const String _sessionEntity = 'study_session';

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  // ---- createResource -----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> createResource({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateResourceInput input,
  }) {
    final bool manual = input.progressMode == LearningProgressMode.manual;
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create_resource',
      'life_area_id': input.lifeAreaId,
      'title': input.title,
      'resource_type': input.type.wire,
      'status': input.status.wire,
      'progress_mode': input.progressMode.wire,
      if (input.sourceUri != null) 'source_uri': input.sourceUri,
      if (input.creator != null) 'creator': input.creator,
      if (input.noteId != null) 'note_id': input.noteId,
      if (manual) 'manual_permille': input.manualProgressPermille,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.resource.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createResourceBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _createResourceBody(
    TransactionSession session,
    ProfileId profileId,
    CreateResourceInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final int now = _now;
    final bool manual = input.progressMode == LearningProgressMode.manual;

    final LearningResource resource;
    try {
      resource = LearningResource(
        id: LearningResourceId(idGenerator.uuidV7()),
        profileId: profileId,
        lifeAreaId: LifeAreaId(input.lifeAreaId),
        title: input.title,
        type: input.type,
        status: input.status,
        progressMode: input.progressMode,
        sourceUri: input.sourceUri,
        creator: input.creator,
        noteId: input.noteId,
        // A derived resource never stores a manual value (DB CHECK).
        manualProgressPermille: manual ? input.manualProgressPermille : null,
        rank: LearningRank.initial,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_resource', cause: e.message);
    }
    await repo.insertResource(resource);

    return _write(
      resultCode: 'resource_created',
      resultPayload: '{"resource_id":"${resource.id.value}"}',
      searchEntityId: resource.id.value,
      activityEntity: _resourceEntity,
      activityEntityId: resource.id.value,
      eventType: 'resource_created',
      operations: <OutboxOperationDraft>[_resourceOp(resource, insert: true)],
    );
  }

  // ---- updateResource -----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> updateResource({
    required CommandId commandId,
    required ProfileId profileId,
    required UpdateResourceInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_resource',
      'resource_id': input.resourceId,
      if (input.title != null) 'title': input.title,
      if (input.type != null) 'resource_type': input.type!.wire,
      if (input.status != null) 'status': input.status!.wire,
      if (input.progressMode != null) 'progress_mode': input.progressMode!.wire,
      ..._editCanonical('source_uri', input.sourceUri),
      ..._editCanonical('creator', input.creator),
      ..._editCanonical('note_id', input.noteId),
      ..._editCanonical('manual_permille', input.manualProgressPermille),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.resource.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateResourceBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _updateResourceBody(
    TransactionSession session,
    ProfileId profileId,
    UpdateResourceInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningResource? existing = await repo.findResource(
      profileId.value,
      input.resourceId,
    );
    if (existing == null || existing.isDeleted) {
      throw _NotFound('learning.resource_not_found', input.resourceId);
    }

    final LearningProgressMode mode =
        input.progressMode ?? existing.progressMode;

    // Resolve the manual value under the target mode. Switching to derived
    // clears it (DB CHECK); switching to/staying manual requires a value.
    int? manual = existing.manualProgressPermille;
    if (input.manualProgressPermille.isClear) {
      manual = null;
    } else if (input.manualProgressPermille.isSet) {
      manual = input.manualProgressPermille.value;
    }
    if (mode == LearningProgressMode.derived) {
      manual = null;
    } else if (manual == null) {
      throw const _Validation('learning.manual_progress_required');
    }

    final LearningResource updated;
    try {
      updated = existing.copyWith(
        title: input.title,
        type: input.type,
        status: input.status,
        progressMode: mode,
        sourceUri: _resolveEdit(input.sourceUri),
        creator: _resolveEdit(input.creator),
        noteId: _resolveEdit(input.noteId),
        manualProgressPermille: manual,
        revision: existing.revision + 1,
        updatedAtUtc: _now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_resource', cause: e.message);
    }
    await repo.updateResource(updated);

    return _write(
      resultCode: 'resource_updated',
      resultPayload: '{"resource_id":"${updated.id.value}"}',
      searchEntityId: updated.id.value,
      activityEntity: _resourceEntity,
      activityEntityId: updated.id.value,
      eventType: 'resource_updated',
      operations: <OutboxOperationDraft>[_resourceOp(updated, insert: false)],
    );
  }

  // ---- deleteResource -----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> deleteResource({
    required CommandId commandId,
    required ProfileId profileId,
    required String resourceId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'delete_resource',
      'resource_id': resourceId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.resource.delete',
      canonical: canonical,
      body: (TransactionSession session) =>
          _deleteResourceBody(session, profileId, resourceId),
    );
  }

  Future<SemanticWrite> _deleteResourceBody(
    TransactionSession session,
    ProfileId profileId,
    String resourceId,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningResource? existing = await repo.findResource(
      profileId.value,
      resourceId,
    );
    if (existing == null || existing.isDeleted) {
      throw _NotFound('learning.resource_not_found', resourceId);
    }
    final int now = _now;
    final LearningResource deleted = existing.copyWith(
      revision: existing.revision + 1,
      updatedAtUtc: now,
      deletedAtUtc: now,
    );
    await repo.updateResource(deleted);

    return _write(
      resultCode: 'resource_deleted',
      resultPayload: '{"resource_id":"$resourceId"}',
      // A search marker whose projector now returns null tombstones the doc.
      searchEntityId: resourceId,
      activityEntity: _resourceEntity,
      activityEntityId: resourceId,
      eventType: 'resource_deleted',
      operations: <OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: _resourceEntity,
          entityId: resourceId,
          opKind: 'delete',
          payload: LearningCanonicalRequest.encode(<String, Object?>{
            'id': resourceId,
          }),
        ),
      ],
    );
  }

  // ---- addItem ------------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> addItem({
    required CommandId commandId,
    required ProfileId profileId,
    required AddItemInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'add_item',
      'resource_id': input.resourceId,
      'title': input.title,
      'item_type': input.type.wire,
      if (input.parentId != null) 'parent_id': input.parentId,
      if (input.sourceUri != null) 'source_uri': input.sourceUri,
      if (input.durationSec != null) 'duration_sec': input.durationSec,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.item.add',
      canonical: canonical,
      body: (TransactionSession session) =>
          _addItemBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _addItemBody(
    TransactionSession session,
    ProfileId profileId,
    AddItemInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final int now = _now;
    final LearningResource? resource = await repo.findResource(
      profileId.value,
      input.resourceId,
    );
    if (resource == null || resource.isDeleted) {
      throw _NotFound('learning.resource_not_found', input.resourceId);
    }
    if (input.parentId != null) {
      final LearningItem? parent = await repo.findItem(
        profileId.value,
        input.parentId!,
      );
      if (parent == null || parent.courseId != input.resourceId) {
        throw _NotFound('learning.parent_not_found', input.parentId!);
      }
    }
    final String? lastRank = await repo.lastItemRank(
      profileId.value,
      input.resourceId,
    );
    final String itemId = idGenerator.uuidV7();
    final LearningItem item;
    try {
      item = LearningItem(
        id: itemId,
        profileId: profileId.value,
        courseId: input.resourceId,
        parentId: input.parentId,
        title: input.title,
        type: input.type,
        sourceUri: input.sourceUri,
        durationSec: input.durationSec,
        rank: LearningRank.append(lastRank),
        createdAtUtc: now,
        updatedAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_item', cause: e.message);
    }
    await repo.insertItem(item);

    return _write(
      resultCode: 'item_added',
      resultPayload: '{"item_id":"$itemId"}',
      activityEntity: _itemEntity,
      activityEntityId: itemId,
      eventType: 'item_added',
      operations: <OutboxOperationDraft>[_itemOp(item, insert: true)],
    );
  }

  // ---- updateItem ---------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> updateItem({
    required CommandId commandId,
    required ProfileId profileId,
    required UpdateItemInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update_item',
      'item_id': input.itemId,
      if (input.title != null) 'title': input.title,
      if (input.type != null) 'item_type': input.type!.wire,
      ..._editCanonical('source_uri', input.sourceUri),
      ..._editCanonical('duration_sec', input.durationSec),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.item.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateItemBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _updateItemBody(
    TransactionSession session,
    ProfileId profileId,
    UpdateItemInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningItem? existing = await repo.findItem(
      profileId.value,
      input.itemId,
    );
    if (existing == null) {
      throw _NotFound('learning.item_not_found', input.itemId);
    }
    final LearningItemType newType = input.type ?? existing.type;
    // A section is never an eligible leaf; converting a completed leaf into a
    // section would strand a completion instant, so reject it.
    if (!newType.eligibleLeaf && existing.isComplete) {
      throw const _Validation('learning.section_cannot_be_complete');
    }
    final LearningItem updated;
    try {
      updated = existing.copyWith(
        title: input.title,
        type: input.type,
        sourceUri: _resolveEdit(input.sourceUri),
        durationSec: _resolveEditInt(input.durationSec),
        updatedAtUtc: _now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_item', cause: e.message);
    }
    await repo.updateItem(updated);

    return _write(
      resultCode: 'item_updated',
      resultPayload: '{"item_id":"${updated.id}"}',
      activityEntity: _itemEntity,
      activityEntityId: updated.id,
      eventType: 'item_updated',
      operations: <OutboxOperationDraft>[_itemOp(updated, insert: false)],
    );
  }

  // ---- moveItem -----------------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> moveItem({
    required CommandId commandId,
    required ProfileId profileId,
    required MoveItemInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move_item',
      'item_id': input.itemId,
      if (input.afterItemId != null) 'after_item_id': input.afterItemId,
      if (input.beforeItemId != null) 'before_item_id': input.beforeItemId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.item.move',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveItemBody(session, profileId, input),
    );
  }

  Future<SemanticWrite> _moveItemBody(
    TransactionSession session,
    ProfileId profileId,
    MoveItemInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningItem? item = await repo.findItem(
      profileId.value,
      input.itemId,
    );
    if (item == null) {
      throw _NotFound('learning.item_not_found', input.itemId);
    }
    String? beforeRank;
    String? afterRank;
    if (input.afterItemId != null) {
      final LearningItem? after = await repo.findItem(
        profileId.value,
        input.afterItemId!,
      );
      if (after == null || after.courseId != item.courseId) {
        throw _NotFound('learning.item_not_found', input.afterItemId!);
      }
      beforeRank = after.rank;
    }
    if (input.beforeItemId != null) {
      final LearningItem? before = await repo.findItem(
        profileId.value,
        input.beforeItemId!,
      );
      if (before == null || before.courseId != item.courseId) {
        throw _NotFound('learning.item_not_found', input.beforeItemId!);
      }
      afterRank = before.rank;
    }
    final String newRank;
    try {
      newRank = LearningRank.between(beforeRank, afterRank);
    } on ArgumentError catch (e) {
      throw _Validation('learning.invalid_move', cause: '${e.message}');
    }
    final LearningItem moved = item.copyWith(rank: newRank, updatedAtUtc: _now);
    await repo.updateItem(moved);

    return _write(
      resultCode: 'item_moved',
      resultPayload: '{"item_id":"${moved.id}","rank":"$newRank"}',
      activityEntity: _itemEntity,
      activityEntityId: moved.id,
      eventType: 'item_moved',
      operations: <OutboxOperationDraft>[_itemOp(moved, insert: false)],
    );
  }

  // ---- completeItem / reopenItem -----------------------------------------

  @override
  Future<Result<CommittedCommandResult>> completeItem({
    required CommandId commandId,
    required ProfileId profileId,
    required String itemId,
    required int completedAtUtc,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'complete_item',
      'item_id': itemId,
      'completed_at_utc': completedAtUtc,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.item.complete',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setItemCompletionBody(session, profileId, itemId, completedAtUtc),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> reopenItem({
    required CommandId commandId,
    required ProfileId profileId,
    required String itemId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'reopen_item',
      'item_id': itemId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.item.reopen',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setItemCompletionBody(session, profileId, itemId, null),
    );
  }

  Future<SemanticWrite> _setItemCompletionBody(
    TransactionSession session,
    ProfileId profileId,
    String itemId,
    int? completedAtUtc,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final LearningItem? existing = await repo.findItem(profileId.value, itemId);
    if (existing == null) {
      throw _NotFound('learning.item_not_found', itemId);
    }
    if (completedAtUtc != null && !existing.isEligible) {
      // A section is a container, not an eligible leaf, so it cannot complete.
      throw const _Validation('learning.section_cannot_be_complete');
    }
    final LearningItem updated = existing.copyWith(
      completedAtUtc: completedAtUtc,
      updatedAtUtc: _now,
    );
    await repo.updateItem(updated);
    final String code = completedAtUtc == null
        ? 'item_reopened'
        : 'item_completed';
    return _write(
      resultCode: code,
      resultPayload: '{"item_id":"$itemId"}',
      activityEntity: _itemEntity,
      activityEntityId: itemId,
      eventType: code,
      operations: <OutboxOperationDraft>[_itemOp(updated, insert: false)],
    );
  }

  // ---- logStudySession ----------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> logStudySession({
    required CommandId commandId,
    required ProfileId profileId,
    required LogStudySessionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'log_study_session',
      'resource_id': input.resourceId,
      'started_at_utc': input.startedAtUtc,
      'ended_at_utc': input.endedAtUtc,
      if (input.itemId != null) 'item_id': input.itemId,
      if (input.focusSessionId != null)
        'focus_session_id': input.focusSessionId,
      if (input.note != null) 'note': input.note,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.study.log',
      canonical: canonical,
      body: (TransactionSession session) =>
          _logStudySessionBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _logStudySessionBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    LogStudySessionInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final int now = _now;
    final LearningResource? resource = await repo.findResource(
      profileId.value,
      input.resourceId,
    );
    if (resource == null || resource.isDeleted) {
      throw _NotFound('learning.resource_not_found', input.resourceId);
    }
    if (input.itemId != null) {
      final LearningItem? item = await repo.findItem(
        profileId.value,
        input.itemId!,
      );
      if (item == null || item.courseId != input.resourceId) {
        throw _NotFound('learning.item_not_found', input.itemId!);
      }
    }
    final int span = input.endedAtUtc - input.startedAtUtc;
    if (span < 0) {
      throw const _Validation('learning.session_end_before_start');
    }
    final int duration = span ~/ StudySession.microsPerSecond;

    final String logicalId = idGenerator.uuidV7();
    final String rowId = idGenerator.uuidV7();
    final StudySession sessionRow;
    try {
      sessionRow = StudySession(
        id: rowId,
        profileId: profileId.value,
        courseId: input.resourceId,
        logicalId: logicalId,
        startedAtUtc: input.startedAtUtc,
        endedAtUtc: input.endedAtUtc,
        durationSec: duration,
        itemId: input.itemId,
        focusSessionId: input.focusSessionId,
        note: input.note,
        version: 1,
        isCurrent: true,
        createdAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_session', cause: e.message);
    }
    await repo.insertSession(sessionRow);
    await repo.insertSessionEvent(
      StudySessionEvent(
        id: idGenerator.uuidV7(),
        profileId: profileId.value,
        sessionId: rowId,
        logicalId: logicalId,
        kind: StudySessionEventKind.logged,
        commandId: commandId.value,
        payloadVersion: _payloadVersion,
        occurredAtUtc: now,
      ),
    );

    return _write(
      resultCode: 'study_session_logged',
      resultPayload:
          '{"logical_id":"$logicalId","session_id":"$rowId","duration_sec":$duration}',
      activityEntity: _sessionEntity,
      activityEntityId: logicalId,
      eventType: 'study_session_logged',
      operations: <OutboxOperationDraft>[_sessionOp(sessionRow, insert: true)],
    );
  }

  // ---- correctStudySession ------------------------------------------------

  @override
  Future<Result<CommittedCommandResult>> correctStudySession({
    required CommandId commandId,
    required ProfileId profileId,
    required CorrectStudySessionInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'correct_study_session',
      'logical_id': input.logicalId,
      if (input.startedAtUtc != null) 'started_at_utc': input.startedAtUtc,
      if (input.endedAtUtc != null) 'ended_at_utc': input.endedAtUtc,
      ..._editCanonical('item_id', input.itemId),
      ..._editCanonical('focus_session_id', input.focusSessionId),
      ..._editCanonical('note', input.note),
      if (input.reason != null) 'reason': input.reason,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'learning.study.correct',
      canonical: canonical,
      body: (TransactionSession session) =>
          _correctStudySessionBody(session, profileId, commandId, input),
    );
  }

  Future<SemanticWrite> _correctStudySessionBody(
    TransactionSession session,
    ProfileId profileId,
    CommandId commandId,
    CorrectStudySessionInput input,
  ) async {
    final LearningWriteRepository repo = session.repositories
        .resolve<LearningWriteRepository>();
    final int now = _now;
    final StudySession? current = await repo.currentSession(
      profileId.value,
      input.logicalId,
    );
    if (current == null) {
      throw _NotFound('learning.session_not_found', input.logicalId);
    }

    final int started = input.startedAtUtc ?? current.startedAtUtc;
    final int ended = input.endedAtUtc ?? current.endedAtUtc;
    final int span = ended - started;
    if (span < 0) {
      throw const _Validation('learning.session_end_before_start');
    }
    final int duration = span ~/ StudySession.microsPerSecond;
    final String? itemId = input.itemId.isUnchanged
        ? current.itemId
        : (input.itemId.isClear ? null : input.itemId.value);
    if (itemId != null) {
      final LearningItem? item = await repo.findItem(profileId.value, itemId);
      if (item == null || item.courseId != current.courseId) {
        throw _NotFound('learning.item_not_found', itemId);
      }
    }
    final String? focusId = input.focusSessionId.isUnchanged
        ? current.focusSessionId
        : (input.focusSessionId.isClear ? null : input.focusSessionId.value);
    final String? note = input.note.isUnchanged
        ? current.note
        : (input.note.isClear ? null : input.note.value);

    final String newRowId = idGenerator.uuidV7();
    final StudySession corrected;
    try {
      corrected = StudySession(
        id: newRowId,
        profileId: profileId.value,
        courseId: current.courseId,
        logicalId: current.logicalId,
        startedAtUtc: started,
        endedAtUtc: ended,
        durationSec: duration,
        itemId: itemId,
        focusSessionId: focusId,
        note: note,
        version: current.version + 1,
        supersedesId: current.id,
        isCurrent: true,
        createdAtUtc: now,
      );
    } on FormatException catch (e) {
      throw _Validation('learning.invalid_session', cause: e.message);
    }
    // Flip the prior version's projection flag, then insert the superseding
    // version so the partial-unique current index is never violated.
    await repo.clearCurrent(profileId.value, current.id);
    await repo.insertSession(corrected);
    await repo.insertSessionEvent(
      StudySessionEvent(
        id: idGenerator.uuidV7(),
        profileId: profileId.value,
        sessionId: newRowId,
        logicalId: current.logicalId,
        kind: StudySessionEventKind.corrected,
        commandId: commandId.value,
        payload: input.reason == null
            ? null
            : LearningCanonicalRequest.encode(<String, Object?>{
                'reason': input.reason,
              }),
        payloadVersion: _payloadVersion,
        occurredAtUtc: now,
        supersedesId: current.id,
      ),
    );

    return _write(
      resultCode: 'study_session_corrected',
      resultPayload:
          '{"logical_id":"${current.logicalId}","session_id":"$newRowId",'
          '"version":${corrected.version}}',
      activityEntity: _sessionEntity,
      activityEntityId: current.logicalId,
      eventType: 'study_session_corrected',
      operations: <OutboxOperationDraft>[_sessionOp(corrected, insert: true)],
    );
  }

  // ---- helpers ------------------------------------------------------------

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = LearningCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: LearningCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.learning.not_found',
          retryable: false,
          redactedCause: e.id,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.learning.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required String activityEntity,
    required String activityEntityId,
    required String eventType,
    required List<OutboxOperationDraft> operations,
    String? searchEntityId,
  }) {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: eventType,
          entityType: activityEntity,
          entityId: activityEntityId,
          payloadVersion: _payloadVersion,
        ),
      ],
      dirtyProjections: <DirtyProjectionDraft>[
        if (searchEntityId != null)
          DirtyProjectionDraft(
            projection: SearchDirtyKey.projection,
            projectionKey: SearchDirtyKey.encode(
              LearningSearchProjector.kind,
              searchEntityId,
            ),
          ),
      ],
      outboxGroup: operations.isEmpty
          ? null
          : OutboxGroupDraft(
              groupId: idGenerator.uuidV7(),
              snapshotEpoch: 0,
              operations: operations,
            ),
    );
  }

  Map<String, Object?> _editCanonical<T>(String name, FieldEdit<T> edit) {
    if (edit.isUnchanged) {
      return const <String, Object?>{};
    }
    return <String, Object?>{name: edit.isClear ? null : edit.value};
  }

  /// Maps a tri-state string edit onto the [LearningResource]/[LearningItem]
  /// copyWith sentinel: unchanged → keep, clear → null, set → value.
  Object? _resolveEdit(FieldEdit<String> edit) {
    if (edit.isUnchanged) {
      return keepEdit;
    }
    return edit.isClear ? null : edit.value;
  }

  Object? _resolveEditInt(FieldEdit<int> edit) {
    if (edit.isUnchanged) {
      return keepEdit;
    }
    return edit.isClear ? null : edit.value;
  }

  OutboxOperationDraft _resourceOp(
    LearningResource resource, {
    required bool insert,
  }) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: _resourceEntity,
    entityId: resource.id.value,
    opKind: insert ? 'insert' : 'patch',
    baseRowVersion: insert ? null : resource.revision - 1,
    payload: LearningCanonicalRequest.encode(<String, Object?>{
      'id': resource.id.value,
      'life_area_id': resource.lifeAreaId.value,
      'title': resource.title,
      'resource_type': resource.type.wire,
      'source_uri': resource.sourceUri,
      'creator': resource.creator,
      'status': resource.status.wire,
      'progress_mode': resource.progressMode.wire,
      'manual_permille': resource.manualProgressPermille,
      'note_id': resource.noteId,
      'rank': resource.rank,
      'revision': resource.revision,
      'deleted_at_utc': resource.deletedAtUtc,
    }),
  );

  OutboxOperationDraft _itemOp(LearningItem item, {required bool insert}) =>
      OutboxOperationDraft(
        operationId: idGenerator.uuidV7(),
        entityType: _itemEntity,
        entityId: item.id,
        opKind: insert ? 'insert' : 'patch',
        payload: LearningCanonicalRequest.encode(<String, Object?>{
          'id': item.id,
          'course_id': item.courseId,
          'parent_id': item.parentId,
          'title': item.title,
          'item_type': item.type.wire,
          'source_uri': item.sourceUri,
          'duration_sec': item.durationSec,
          'completed_at_utc': item.completedAtUtc,
          'rank': item.rank,
        }),
      );

  OutboxOperationDraft _sessionOp(
    StudySession session, {
    required bool insert,
  }) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: _sessionEntity,
    entityId: session.id,
    opKind: 'insert',
    payload: LearningCanonicalRequest.encode(<String, Object?>{
      'id': session.id,
      'course_id': session.courseId,
      'logical_id': session.logicalId,
      'item_id': session.itemId,
      'focus_session_id': session.focusSessionId,
      'started_at_utc': session.startedAtUtc,
      'ended_at_utc': session.endedAtUtc,
      'duration_sec': session.durationSec,
      'note': session.note,
      'version': session.version,
      'supersedes_id': session.supersedesId,
      'is_current': session.isCurrent,
    }),
  );
}
