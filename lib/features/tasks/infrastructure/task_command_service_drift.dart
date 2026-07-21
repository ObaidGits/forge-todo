import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/search/application/search_contracts.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_policies.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_status.dart';
import 'package:forge/features/tasks/infrastructure/canonical_request.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';
import 'package:forge/features/tasks/infrastructure/task_write_repository.dart';

// Private control-flow exceptions raised inside a command body. They roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper,
// mirroring the DeletionService pattern.
final class _NotFound implements Exception {
  const _NotFound(this.taskId);
  final String taskId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

final class _Hierarchy implements Exception {
  const _Hierarchy(this.violation);
  final HierarchyViolation violation;
}

/// Command-bus-backed implementation of [TaskCommandService] (R-TASK-*,
/// R-GEN-005). Every mutation is one atomic transaction; bulk operations write
/// one semantic group over all affected rows.
final class DriftTaskCommandService implements TaskCommandService {
  DriftTaskCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateTaskInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create',
      'life_area_id': input.lifeAreaId.value,
      'title': input.title,
      'priority': input.priority.wire,
      'scheduled_date': input.scheduledDate,
      'due_date': input.due.dueDate,
      'due_at_utc': input.due.dueAtUtc,
      'due_timezone': input.due.timezoneId,
      'estimate_minutes': input.estimateMinutes,
      'note_id': input.noteId?.value,
      'parent_task_id': input.parentTaskId?.value,
      'tag_ids': input.tagIds,
      'in_progress': input.markInProgress,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createBody(session, profileId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required UpdateTaskInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update',
      'task_id': taskId.value,
      if (input.title != null) 'title': input.title,
      if (input.priority != null) 'priority': input.priority!.wire,
      if (input.due != null) 'due_date': input.due!.dueDate,
      if (input.due != null) 'due_at_utc': input.due!.dueAtUtc,
      if (input.due != null) 'due_timezone': input.due!.timezoneId,
      if (input.scheduledDate != null)
        'scheduled_date': input.scheduledDate!.value,
      if (input.estimateMinutes != null)
        'estimate_minutes': input.estimateMinutes!.value,
      if (input.noteId != null) 'note_id': input.noteId!.value?.value,
      if (input.lifeAreaId != null) 'life_area_id': input.lifeAreaId!.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateBody(session, profileId, taskId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> complete({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => _statusTransition(
    commandId: commandId,
    profileId: profileId,
    taskIds: <TaskId>[taskId],
    commandType: 'task.complete',
    op: _StatusOp.complete,
  );

  @override
  Future<Result<CommittedCommandResult>> reopen({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => _statusTransition(
    commandId: commandId,
    profileId: profileId,
    taskIds: <TaskId>[taskId],
    commandType: 'task.reopen',
    op: _StatusOp.reopen,
  );

  @override
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => _statusTransition(
    commandId: commandId,
    profileId: profileId,
    taskIds: <TaskId>[taskId],
    commandType: 'task.cancel',
    op: _StatusOp.cancel,
  );

  @override
  Future<Result<CommittedCommandResult>> completeMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  }) => _statusTransition(
    commandId: commandId,
    profileId: profileId,
    taskIds: taskIds,
    commandType: 'task.complete_many',
    op: _StatusOp.complete,
  );

  @override
  Future<Result<CommittedCommandResult>> cancelMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  }) => _statusTransition(
    commandId: commandId,
    profileId: profileId,
    taskIds: taskIds,
    commandType: 'task.cancel_many',
    op: _StatusOp.cancel,
  );

  @override
  Future<Result<CommittedCommandResult>> move({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required MoveTaskInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'move',
      'task_id': taskId.value,
      if (input.reparent != null) 'reparent': input.reparent!.value?.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.move',
      canonical: canonical,
      body: (TransactionSession session) =>
          _moveBody(session, profileId, taskId, input),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createBody(
    TransactionSession session,
    ProfileId profileId,
    CreateTaskInput input,
  ) async {
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    final int now = _now;
    LifeAreaId area = input.lifeAreaId;

    // A subtask inherits its parent's area and must keep the hierarchy acyclic
    // and bounded (R-TASK-003).
    if (input.parentTaskId != null) {
      final Task? parent = await repo.find(
        profileId.value,
        input.parentTaskId!.value,
      );
      if (parent == null) {
        throw _NotFound(input.parentTaskId!.value);
      }
      if (parent.isDeleted) {
        throw const _Validation('task.parent_deleted');
      }
      area = parent.lifeAreaId;
      final List<String> chain = <String>[
        parent.id.value,
        ...await repo.ancestorChain(profileId.value, parent.id.value),
      ];
      final HierarchyViolation? violation = TaskPolicies.validateReparent(
        movingTaskId: 'new',
        ancestorChain: chain,
        descendantDepth: 1,
      );
      if (violation != null) {
        throw _Hierarchy(violation);
      }
    }

    final TaskRank rank = TaskRank.append(
      await repo.lastSiblingRank(
        profileId.value,
        parentTaskId: input.parentTaskId?.value,
      ),
    );

    final String taskId = idGenerator.uuidV7();
    final Task task = _guardConstruct(
      () => Task(
        id: TaskId(taskId),
        profileId: profileId,
        lifeAreaId: area,
        parentTaskId: input.parentTaskId,
        title: input.title,
        status: input.markInProgress ? TaskStatus.inProgress : TaskStatus.open,
        priority: input.priority,
        scheduledDate: input.scheduledDate,
        due: input.due,
        estimateMinutes: input.estimateMinutes,
        noteId: input.noteId,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );

    await repo.insert(task);
    for (final String tagId in input.tagIds) {
      await repo.attachTag(
        profileId: profileId.value,
        taskId: taskId,
        tagId: tagId,
        nowUtc: now,
      );
    }

    final int epoch = await repo.currentEpoch(profileId.value);
    return SemanticWrite(
      resultCode: 'created',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"$taskId"}',
      activity: <ActivityDraft>[_activity('created', taskId)],
      dirtyProjections: _dirty(taskId),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: 'task',
          entityId: taskId,
          opKind: 'insert',
          payload: _taskPayload(task),
        ),
      ], epoch),
      afterCommitHints: <AfterCommitHint>[
        const AfterCommitHint(
          kind: 'projection',
          entityType: 'task',
          entityId: 'today',
        ),
      ],
    );
  }

  Future<SemanticWrite> _updateBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    UpdateTaskInput input,
  ) async {
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    final Task? current = await repo.find(profileId.value, taskId.value);
    if (current == null) {
      throw _NotFound(taskId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('task.deleted');
    }
    if (input.isEmpty) {
      return _noop(taskId.value);
    }

    // Area change is only safe for a top-level task with no subtasks; a
    // subtask inherits its parent's area and a parent's descendants reference
    // its area through composite FKs (data-model §1).
    if (input.lifeAreaId != null &&
        input.lifeAreaId!.value != current.lifeAreaId.value) {
      if (current.isSubtask) {
        throw const _Validation('task.subtask_area_fixed');
      }
      final int depth = await repo.subtreeDepth(profileId.value, taskId.value);
      if (depth > 1) {
        throw const _Validation('task.parent_area_fixed');
      }
    }

    final int now = _now;
    final Task updated = _guardConstruct(
      () => current.copyWith(
        title: input.title,
        priority: input.priority,
        due: input.due,
        scheduledDate: input.scheduledDate == null
            ? Task.unchanged
            : input.scheduledDate!.value,
        estimateMinutes: input.estimateMinutes == null
            ? Task.unchanged
            : input.estimateMinutes!.value,
        noteId: input.noteId == null ? Task.unchanged : input.noteId!.value,
        lifeAreaId: input.lifeAreaId,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    await repo.update(updated);

    return SemanticWrite(
      resultCode: 'updated',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"${taskId.value}"}',
      activity: <ActivityDraft>[_activity('updated', taskId.value)],
      dirtyProjections: _dirty(taskId.value),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: 'task',
          entityId: taskId.value,
          opKind: 'patch',
          baseRowVersion: current.revision,
          payload: _taskPayload(updated),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  Future<SemanticWrite> _moveBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    MoveTaskInput input,
  ) async {
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    final Task? current = await repo.find(profileId.value, taskId.value);
    if (current == null) {
      throw _NotFound(taskId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('task.deleted');
    }

    Object? newParent = Task.unchanged;
    LifeAreaId area = current.lifeAreaId;
    if (input.reparent != null) {
      final TaskId? target = input.reparent!.value;
      if (target != null) {
        if (target.value == taskId.value) {
          throw const _Hierarchy(HierarchyViolation.cycle);
        }
        final Task? parent = await repo.find(profileId.value, target.value);
        if (parent == null) {
          throw _NotFound(target.value);
        }
        if (parent.isDeleted) {
          throw const _Validation('task.parent_deleted');
        }
        if (parent.lifeAreaId.value != current.lifeAreaId.value) {
          throw const _Validation('task.cross_area_reparent');
        }
        final List<String> chain = <String>[
          parent.id.value,
          ...await repo.ancestorChain(profileId.value, parent.id.value),
        ];
        final int depth = await repo.subtreeDepth(
          profileId.value,
          taskId.value,
        );
        final HierarchyViolation? violation = TaskPolicies.validateReparent(
          movingTaskId: taskId.value,
          ancestorChain: chain,
          descendantDepth: depth,
        );
        if (violation != null) {
          throw _Hierarchy(violation);
        }
        area = parent.lifeAreaId;
      }
      newParent = target;
    }

    TaskRank rank = current.rank;
    if (input.beforeRank != null || input.afterRank != null) {
      rank = TaskRank.between(
        input.beforeRank == null ? null : TaskRank.parse(input.beforeRank!),
        input.afterRank == null ? null : TaskRank.parse(input.afterRank!),
      );
    }

    final int now = _now;
    final Task moved = current.copyWith(
      parentTaskId: newParent,
      lifeAreaId: area,
      rank: rank,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(moved);

    return SemanticWrite(
      resultCode: 'moved',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"${taskId.value}","rank":"${rank.value}"}',
      activity: <ActivityDraft>[_activity('moved', taskId.value)],
      dirtyProjections: _dirty(taskId.value),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: 'task',
          entityId: taskId.value,
          opKind: 'patch',
          changedFields: 'rank,parent_task_id,life_area_id',
          baseRowVersion: current.revision,
          payload: _taskPayload(moved),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  Future<Result<CommittedCommandResult>> _statusTransition({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
    required String commandType,
    required _StatusOp op,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': op.name,
      'task_ids': taskIds.map((TaskId t) => t.value).toList(growable: false),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      canonical: canonical,
      body: (TransactionSession session) =>
          _statusBody(session, profileId, taskIds, op),
    );
  }

  Future<SemanticWrite> _statusBody(
    TransactionSession session,
    ProfileId profileId,
    List<TaskId> taskIds,
    _StatusOp op,
  ) async {
    if (taskIds.isEmpty) {
      throw const _Validation('task.empty_selection');
    }
    final TaskWriteRepository repo = session.repositories
        .resolve<TaskWriteRepository>();
    final int now = _now;
    final List<ActivityDraft> activity = <ActivityDraft>[];
    final List<DirtyProjectionDraft> dirty = <DirtyProjectionDraft>[];
    final List<OutboxOperationDraft> operations = <OutboxOperationDraft>[];
    final int epoch = await repo.currentEpoch(profileId.value);

    for (final TaskId taskId in taskIds) {
      final Task? current = await repo.find(profileId.value, taskId.value);
      if (current == null) {
        throw _NotFound(taskId.value);
      }
      if (current.isDeleted) {
        throw const _Validation('task.deleted');
      }
      final Task? next = _applyStatus(current, op, now);
      if (next == null) {
        continue; // idempotent no-op for this row
      }
      await repo.update(next);
      activity.add(_activity(op.eventType, taskId.value));
      dirty.addAll(_dirty(taskId.value));
      operations.add(
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: 'task',
          entityId: taskId.value,
          opKind: 'patch',
          changedFields: 'status,completed_at_utc',
          baseRowVersion: current.revision,
          payload: _taskPayload(next),
        ),
      );
    }

    return SemanticWrite(
      resultCode: activity.isEmpty ? 'noop' : op.resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: '{"affected":${activity.length}}',
      activity: activity,
      dirtyProjections: dirty,
      outboxGroup: _group(operations, epoch),
    );
  }

  /// Returns the next task state for [op], or null when the operation is a
  /// no-op for the current state (idempotent).
  Task? _applyStatus(Task current, _StatusOp op, int now) {
    switch (op) {
      case _StatusOp.complete:
        if (current.status == TaskStatus.completed) {
          return null;
        }
        if (current.status == TaskStatus.cancelled) {
          throw const _Validation('task.cannot_complete_cancelled');
        }
        return current.copyWith(
          status: TaskStatus.completed,
          completedAtUtc: now,
          revision: current.revision + 1,
          updatedAtUtc: now,
        );
      case _StatusOp.reopen:
        // Reversible completion (R-TASK-009): restore the actionable state and
        // preserve the original due/schedule metadata, which was never
        // modified by completion.
        if (current.status != TaskStatus.completed) {
          return null;
        }
        return current.copyWith(
          status: TaskStatus.open,
          completedAtUtc: null,
          revision: current.revision + 1,
          updatedAtUtc: now,
        );
      case _StatusOp.cancel:
        if (current.status == TaskStatus.cancelled) {
          return null;
        }
        return current.copyWith(
          status: TaskStatus.cancelled,
          completedAtUtc: null,
          revision: current.revision + 1,
          updatedAtUtc: now,
        );
    }
  }

  // ---- helpers ------------------------------------------------------------

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = CanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: CanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'task.not_found',
          safeMessageKey: 'error.task.not_found',
          retryable: false,
          redactedCause: e.taskId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.task.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    } on _Hierarchy catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.violation == HierarchyViolation.cycle
              ? 'task.hierarchy_cycle'
              : 'task.hierarchy_too_deep',
          safeMessageKey: 'error.task.hierarchy',
          retryable: false,
        ),
      );
    }
  }

  Task _guardConstruct(Task Function() build) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation('task.invalid_field', cause: e.message);
    }
  }

  SemanticWrite _noop(String taskId) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$taskId"}',
  );

  ActivityDraft _activity(String eventType, String taskId) => ActivityDraft(
    id: idGenerator.uuidV7(),
    eventType: eventType,
    entityType: 'task',
    entityId: taskId,
    payloadVersion: _payloadVersion,
  );

  List<DirtyProjectionDraft> _dirty(String taskId) => <DirtyProjectionDraft>[
    // The unified search marker encodes the entity type so the projector
    // registry can route it (design.md §14); Today stays keyed by task id.
    DirtyProjectionDraft(
      projection: SearchDirtyKey.projection,
      projectionKey: SearchDirtyKey.encode(TaskSearchProjector.kind, taskId),
    ),
    DirtyProjectionDraft(projection: 'today', projectionKey: taskId),
  ];

  OutboxGroupDraft? _group(List<OutboxOperationDraft> operations, int epoch) {
    if (operations.isEmpty) {
      return null;
    }
    return OutboxGroupDraft(
      groupId: idGenerator.uuidV7(),
      snapshotEpoch: epoch,
      operations: operations,
    );
  }

  String _taskPayload(Task task) => CanonicalRequest.encode(<String, Object?>{
    'id': task.id.value,
    'life_area_id': task.lifeAreaId.value,
    'parent_task_id': task.parentTaskId?.value,
    'title': task.title,
    'status': task.status.wire,
    'priority': task.priority.wire,
    'scheduled_date': task.scheduledDate,
    'due_date': task.due.dueDate,
    'due_at_utc': task.due.dueAtUtc,
    'due_timezone': task.due.timezoneId,
    'estimate_minutes': task.estimateMinutes,
    'note_id': task.noteId?.value,
    'rank': task.rank.value,
    'completed_at_utc': task.completedAtUtc,
    'revision': task.revision,
  });
}

enum _StatusOp {
  complete('completed', 'completed'),
  reopen('reopened', 'reopened'),
  cancel('cancelled', 'cancelled');

  const _StatusOp(this.eventType, this.resultCode);
  final String eventType;
  final String resultCode;
}
