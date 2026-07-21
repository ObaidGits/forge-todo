import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/tasks/application/recurrence_command_service.dart';
import 'package:forge/features/tasks/application/recurrence_commands.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_engine.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_schedule_version.dart';
import 'package:forge/features/tasks/domain/recurrence/task_occurrence.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_status.dart';
import 'package:forge/features/tasks/infrastructure/canonical_request.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_write_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_write_repository.dart';

// Private control-flow exceptions raised inside a command body. They roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.taskId);
  final String taskId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [RecurrenceCommandService] (R-TASK-005,
/// R-TASK-006, R-TASK-007, R-GEN-004, R-GEN-005).
///
/// The service orchestrates immutable schedule versions and append-only
/// occurrence history through the shared command bus, so every mutation is one
/// atomic transaction with a durable receipt. DST/timezone conversion of timed
/// occurrences is delegated to the injected [TimeZoneResolver]; the recurrence
/// domain policies it calls remain pure.
final class DriftRecurrenceCommandService implements RecurrenceCommandService {
  DriftRecurrenceCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
    required this.timeZoneResolver,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;
  final TimeZoneResolver timeZoneResolver;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<Result<CommittedCommandResult>> setRecurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required SetRecurrenceInput input,
  }) {
    final RecurrenceRule rule = input.rule;
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_recurrence',
      'task_id': taskId.value,
      ..._ruleCanonical(rule),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.recurrence.set',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setRecurrenceBody(session, profileId, taskId, rule),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> completeOccurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'complete_occurrence',
      'task_id': taskId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.recurrence.complete_occurrence',
      canonical: canonical,
      body: (TransactionSession session) =>
          _completeOccurrenceBody(session, profileId, taskId),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> editRecurrence({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required EditRecurrenceInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'edit_recurrence',
      'task_id': taskId.value,
      'scope': input.scope.name,
      'from': input.fromOccurrenceKey.iso,
      if (input.newRule != null) ..._ruleCanonical(input.newRule!),
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.recurrence.edit',
      canonical: canonical,
      body: (TransactionSession session) =>
          _editRecurrenceBody(session, profileId, taskId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> undoLastOccurrenceChange({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'undo_occurrence',
      'task_id': taskId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'task.recurrence.undo',
      canonical: canonical,
      body: (TransactionSession session) =>
          _undoBody(session, profileId, taskId),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _setRecurrenceBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    RecurrenceRule rule,
  ) async {
    final TaskWriteRepository tasks = session.repositories
        .resolve<TaskWriteRepository>();
    final RecurrenceWriteRepository recur = session.repositories
        .resolve<RecurrenceWriteRepository>();
    final int now = _now;

    final Task? task = await tasks.find(profileId.value, taskId.value);
    if (task == null) {
      throw _NotFound(taskId.value);
    }
    if (task.isDeleted) {
      throw const _Validation('task.deleted');
    }
    if (task.recurrenceRuleId != null) {
      throw const _Validation('recurrence.already_set');
    }
    _validateZone(rule);

    final LocalDate? firstKey = RecurrenceEngine.first(rule);
    if (firstKey == null) {
      throw const _Validation('recurrence.no_occurrences');
    }

    final String seriesId = idGenerator.uuidV7();
    final String versionId = idGenerator.uuidV7();
    final RecurrenceScheduleVersion version = RecurrenceScheduleVersion(
      id: versionId,
      seriesId: seriesId,
      version: 1,
      effectiveOccurrenceKey: firstKey,
      rule: rule,
    );
    await recur.insertScheduleVersion(
      version,
      profileId: profileId.value,
      taskId: taskId.value,
      nowUtc: now,
    );

    final _OccurrenceDue due = _dueFor(rule, firstKey);
    final String occurrenceId = idGenerator.uuidV7();
    await recur.insertOccurrence(
      profileId: profileId.value,
      id: occurrenceId,
      taskId: taskId.value,
      scheduleVersionId: versionId,
      originalScheduleVersionId: versionId,
      occurrenceKey: firstKey,
      status: OccurrenceStatus.open,
      nowUtc: now,
      occurrenceDueAtUtc: due.dueAtUtc,
      occurrenceTimezone: due.timezoneId,
    );

    final Task updated = task.copyWith(
      due: due.due,
      recurrenceRuleId: versionId,
      recurrenceVersion: 1,
      revision: task.revision + 1,
      updatedAtUtc: now,
    );
    await tasks.update(updated);

    return _write(
      resultCode: 'recurrence_set',
      resultPayload:
          '{"task_id":"${taskId.value}","schedule_version_id":"$versionId",'
          '"first_occurrence":"${firstKey.iso}"}',
      profileId: profileId,
      recur: recur,
      eventType: 'recurrence_set',
      taskId: taskId.value,
      operations: <OutboxOperationDraft>[
        _taskOp(updated),
        _ruleOp(versionId, taskId.value, rule, firstKey),
      ],
    );
  }

  Future<SemanticWrite> _completeOccurrenceBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
  ) async {
    final TaskWriteRepository tasks = session.repositories
        .resolve<TaskWriteRepository>();
    final RecurrenceWriteRepository recur = session.repositories
        .resolve<RecurrenceWriteRepository>();
    final int now = _now;

    final Task? task = await tasks.find(profileId.value, taskId.value);
    if (task == null) {
      throw _NotFound(taskId.value);
    }
    if (task.isDeleted) {
      throw const _Validation('task.deleted');
    }
    final OccurrenceRecord? open = await recur.findOpenOccurrence(
      profileId.value,
      taskId.value,
    );
    if (open == null) {
      throw const _Validation('recurrence.no_open_occurrence');
    }
    final RecurrenceScheduleVersion? version = await recur.findScheduleVersion(
      profileId.value,
      open.scheduleVersionId,
    );
    if (version == null) {
      throw const _Validation('recurrence.version_missing');
    }

    // Append immutable completion history for the current occurrence.
    await recur.appendOccurrenceEvent(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      occurrenceId: open.id,
      eventKind: OccurrenceEventKind.complete,
      payloadVersion: _payloadVersion,
      nowUtc: now,
      commandId: null,
      payload: '{"key":"${open.occurrenceKey.iso}"}',
    );
    await recur.setOccurrenceStatus(
      profileId: profileId.value,
      occurrenceId: open.id,
      status: OccurrenceStatus.completed,
      nowUtc: now,
    );

    // Resolve the next deterministic occurrence for the same immutable version
    // without rewriting it (R-TASK-006). Exceptions gathered from history are
    // fed to the pure engine.
    final Set<LocalDate> exceptions = await recur.exceptionKeys(
      profileId.value,
      taskId.value,
    );
    final RecurrenceScheduleVersion effective = _withExceptions(
      version,
      exceptions,
    );
    final LocalDate? nextKey = RecurrencePolicies.nextForVersion(
      effective,
      open.occurrenceKey,
    );

    final List<OutboxOperationDraft> ops = <OutboxOperationDraft>[];
    String resultCode;
    Task updated;
    if (nextKey != null) {
      final _OccurrenceDue due = _dueFor(version.rule, nextKey);
      await recur.insertOccurrence(
        profileId: profileId.value,
        id: idGenerator.uuidV7(),
        taskId: taskId.value,
        scheduleVersionId: version.id,
        originalScheduleVersionId: open.originalScheduleVersionId,
        occurrenceKey: nextKey,
        status: OccurrenceStatus.open,
        nowUtc: now,
        occurrenceDueAtUtc: due.dueAtUtc,
        occurrenceTimezone: due.timezoneId,
      );
      updated = task.copyWith(
        due: due.due,
        // The task remains actionable; only the occurrence completed.
        status: TaskStatus.open,
        completedAtUtc: null,
        revision: task.revision + 1,
        updatedAtUtc: now,
      );
      resultCode = 'occurrence_completed';
    } else {
      // Series exhausted: the task itself is now complete.
      updated = task.copyWith(
        status: TaskStatus.completed,
        completedAtUtc: now,
        revision: task.revision + 1,
        updatedAtUtc: now,
      );
      resultCode = 'series_completed';
    }
    await tasks.update(updated);
    ops.add(_taskOp(updated));

    return _write(
      resultCode: resultCode,
      resultPayload:
          '{"task_id":"${taskId.value}","completed":"${open.occurrenceKey.iso}"'
          '${nextKey == null ? '' : ',"next":"${nextKey.iso}"'}}',
      profileId: profileId,
      recur: recur,
      eventType: resultCode,
      taskId: taskId.value,
      operations: ops,
    );
  }

  Future<SemanticWrite> _editRecurrenceBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    EditRecurrenceInput input,
  ) async {
    switch (input.scope) {
      case RecurrenceEditScope.thisOccurrence:
        return _editThisOccurrence(session, profileId, taskId, input);
      case RecurrenceEditScope.thisAndFuture:
        return _editThisAndFuture(session, profileId, taskId, input);
    }
  }

  Future<SemanticWrite> _editThisOccurrence(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    EditRecurrenceInput input,
  ) async {
    final TaskWriteRepository tasks = session.repositories
        .resolve<TaskWriteRepository>();
    final RecurrenceWriteRepository recur = session.repositories
        .resolve<RecurrenceWriteRepository>();
    final int now = _now;

    final Task? task = await tasks.find(profileId.value, taskId.value);
    if (task == null) {
      throw _NotFound(taskId.value);
    }
    final RecurrenceScheduleVersion? version = await recur
        .findOpenScheduleVersion(profileId.value, taskId.value);
    if (version == null) {
      throw const _Validation('recurrence.not_recurring');
    }
    final LocalDate key = input.fromOccurrenceKey;
    if (!RecurrenceEngine.isOccurrence(version.rule, key)) {
      throw const _Validation('recurrence.not_an_occurrence');
    }

    // Materialize (or reuse) the occurrence row, mark it skipped, and record an
    // immutable exception event.
    final OccurrenceRecord? occurrence = await recur.findOccurrenceByKey(
      profileId.value,
      taskId.value,
      key,
    );
    final String occurrenceId = occurrence?.id ?? idGenerator.uuidV7();
    if (occurrence == null) {
      await recur.insertOccurrence(
        profileId: profileId.value,
        id: occurrenceId,
        taskId: taskId.value,
        scheduleVersionId: version.id,
        originalScheduleVersionId: version.id,
        occurrenceKey: key,
        status: OccurrenceStatus.skipped,
        nowUtc: now,
      );
    } else {
      await recur.setOccurrenceStatus(
        profileId: profileId.value,
        occurrenceId: occurrenceId,
        status: OccurrenceStatus.skipped,
        nowUtc: now,
        bumpGeneratedVersion: true,
      );
    }
    await recur.appendOccurrenceEvent(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      occurrenceId: occurrenceId,
      eventKind: OccurrenceEventKind.exception,
      payloadVersion: _payloadVersion,
      nowUtc: now,
      payload: '{"key":"${key.iso}"}',
    );

    final List<OutboxOperationDraft> ops = <OutboxOperationDraft>[];
    // If the excluded occurrence is the current open one, advance the task.
    final OccurrenceRecord? stillOpen = await recur.findOpenOccurrence(
      profileId.value,
      taskId.value,
    );
    Task updated = task;
    if (stillOpen == null) {
      final Set<LocalDate> exceptions = await recur.exceptionKeys(
        profileId.value,
        taskId.value,
      );
      final RecurrenceScheduleVersion effective = _withExceptions(
        version,
        exceptions,
      );
      final LocalDate? nextKey = RecurrencePolicies.nextForVersion(
        effective,
        key,
      );
      if (nextKey != null) {
        final _OccurrenceDue due = _dueFor(version.rule, nextKey);
        await recur.insertOccurrence(
          profileId: profileId.value,
          id: idGenerator.uuidV7(),
          taskId: taskId.value,
          scheduleVersionId: version.id,
          originalScheduleVersionId: version.id,
          occurrenceKey: nextKey,
          status: OccurrenceStatus.open,
          nowUtc: now,
          occurrenceDueAtUtc: due.dueAtUtc,
          occurrenceTimezone: due.timezoneId,
        );
        updated = task.copyWith(
          due: due.due,
          revision: task.revision + 1,
          updatedAtUtc: now,
        );
        await tasks.update(updated);
        ops.add(_taskOp(updated));
      }
    }

    return _write(
      resultCode: 'occurrence_excluded',
      resultPayload: '{"task_id":"${taskId.value}","excluded":"${key.iso}"}',
      profileId: profileId,
      recur: recur,
      eventType: 'occurrence_excluded',
      taskId: taskId.value,
      operations: ops,
    );
  }

  Future<SemanticWrite> _editThisAndFuture(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
    EditRecurrenceInput input,
  ) async {
    final TaskWriteRepository tasks = session.repositories
        .resolve<TaskWriteRepository>();
    final RecurrenceWriteRepository recur = session.repositories
        .resolve<RecurrenceWriteRepository>();
    final int now = _now;
    final RecurrenceRule? newRule = input.newRule;
    if (newRule == null) {
      throw const _Validation('recurrence.new_rule_required');
    }
    _validateZone(newRule);

    final Task? task = await tasks.find(profileId.value, taskId.value);
    if (task == null) {
      throw _NotFound(taskId.value);
    }
    final RecurrenceScheduleVersion? current = await recur
        .findOpenScheduleVersion(profileId.value, taskId.value);
    if (current == null) {
      throw const _Validation('recurrence.not_recurring');
    }
    final LocalDate effectiveKey = input.fromOccurrenceKey;
    if (effectiveKey < current.effectiveOccurrenceKey) {
      throw const _Validation('recurrence.effective_before_version');
    }

    // Anchor the successor rule at the effective key so its pattern starts
    // there while historical keys stay immutable.
    final RecurrenceRule successorRule = _anchorRule(newRule, effectiveKey);
    final String successorId = idGenerator.uuidV7();
    final RecurrenceSplit split = RecurrencePolicies.split(
      current: current,
      effectiveKey: effectiveKey,
      newRule: successorRule,
      successorId: successorId,
    );

    await recur.closeScheduleVersion(
      profileId.value,
      current.id,
      effectiveKey,
      now,
    );
    await recur.insertScheduleVersion(
      split.successor,
      profileId: profileId.value,
      taskId: taskId.value,
      nowUtc: now,
    );

    final LocalDate? firstSuccessorKey = RecurrencePolicies.firstForVersion(
      split.successor,
    );
    if (firstSuccessorKey == null) {
      throw const _Validation('recurrence.successor_empty');
    }

    // Re-point the successor's first occurrence: reuse an already-materialized
    // row at that key, otherwise materialize a fresh one. Record an immutable
    // split event either way.
    final OccurrenceRecord? oldOpen = await recur.findOpenOccurrence(
      profileId.value,
      taskId.value,
    );
    final _OccurrenceDue due = _dueFor(successorRule, firstSuccessorKey);
    final OccurrenceRecord? existingAtKey = await recur.findOccurrenceByKey(
      profileId.value,
      taskId.value,
      firstSuccessorKey,
    );
    final String occurrenceId;
    if (existingAtKey != null) {
      occurrenceId = existingAtKey.id;
      await recur.repointOccurrence(
        profileId: profileId.value,
        occurrenceId: existingAtKey.id,
        scheduleVersionId: successorId,
        status: OccurrenceStatus.open,
        nowUtc: now,
        occurrenceDueAtUtc: due.dueAtUtc,
        occurrenceTimezone: due.timezoneId,
      );
    } else {
      occurrenceId = idGenerator.uuidV7();
      await recur.insertOccurrence(
        profileId: profileId.value,
        id: occurrenceId,
        taskId: taskId.value,
        scheduleVersionId: successorId,
        originalScheduleVersionId: successorId,
        occurrenceKey: firstSuccessorKey,
        status: OccurrenceStatus.open,
        nowUtc: now,
        occurrenceDueAtUtc: due.dueAtUtc,
        occurrenceTimezone: due.timezoneId,
      );
    }
    // Retire a distinct previously-open occurrence that now belongs to the
    // successor range (on or after the effective key).
    if (oldOpen != null &&
        oldOpen.id != occurrenceId &&
        oldOpen.occurrenceKey >= effectiveKey) {
      await recur.setOccurrenceStatus(
        profileId: profileId.value,
        occurrenceId: oldOpen.id,
        status: OccurrenceStatus.overridden,
        nowUtc: now,
      );
    }
    await recur.appendOccurrenceEvent(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      occurrenceId: occurrenceId,
      eventKind: OccurrenceEventKind.split,
      payloadVersion: _payloadVersion,
      nowUtc: now,
      payload:
          '{"from":"${effectiveKey.iso}","predecessor":"${current.id}",'
          '"successor":"$successorId"}',
    );

    // Align the task to the earliest still-open occurrence (normally the
    // successor's first, but a pre-effective-key occurrence may still be open).
    final OccurrenceRecord? earliest = await recur.findOpenOccurrence(
      profileId.value,
      taskId.value,
    );
    final Task updated = task.copyWith(
      due: earliest == null ? due.due : _dueFromOccurrence(earliest),
      recurrenceRuleId: successorId,
      recurrenceVersion: split.successor.version,
      status: TaskStatus.open,
      completedAtUtc: null,
      revision: task.revision + 1,
      updatedAtUtc: now,
    );
    await tasks.update(updated);

    return _write(
      resultCode: 'recurrence_split',
      resultPayload:
          '{"task_id":"${taskId.value}","predecessor":"${current.id}",'
          '"successor":"$successorId","effective":"${effectiveKey.iso}"}',
      profileId: profileId,
      recur: recur,
      eventType: 'recurrence_split',
      taskId: taskId.value,
      operations: <OutboxOperationDraft>[
        _taskOp(updated),
        _ruleOp(successorId, taskId.value, successorRule, firstSuccessorKey),
      ],
    );
  }

  Future<SemanticWrite> _undoBody(
    TransactionSession session,
    ProfileId profileId,
    TaskId taskId,
  ) async {
    final TaskWriteRepository tasks = session.repositories
        .resolve<TaskWriteRepository>();
    final RecurrenceWriteRepository recur = session.repositories
        .resolve<RecurrenceWriteRepository>();
    final int now = _now;

    final Task? task = await tasks.find(profileId.value, taskId.value);
    if (task == null) {
      throw _NotFound(taskId.value);
    }
    final OccurrenceEventRecord? latest = await recur.latestOccurrenceEvent(
      profileId.value,
      taskId.value,
    );
    if (latest == null || latest.eventKind == OccurrenceEventKind.undo) {
      throw const _Validation('recurrence.nothing_to_undo');
    }
    final OccurrenceRecord? occurrence = await recur.findOccurrenceById(
      profileId.value,
      latest.occurrenceId,
    );
    if (occurrence == null) {
      throw const _Validation('recurrence.occurrence_missing');
    }

    // Append a superseding undo event; the superseded event stays immutable.
    await recur.appendOccurrenceEvent(
      profileId: profileId.value,
      id: idGenerator.uuidV7(),
      occurrenceId: occurrence.id,
      eventKind: OccurrenceEventKind.undo,
      payloadVersion: _payloadVersion,
      nowUtc: now,
      supersedesId: latest.id,
      payload: '{"restored":"${occurrence.occurrenceKey.iso}"}',
    );

    // Restore the occurrence to open and revert the task's visible state to
    // that occurrence. Any untouched advanced occurrence is discarded (it is a
    // regenerable projection, not historical fact).
    await recur.setOccurrenceStatus(
      profileId: profileId.value,
      occurrenceId: occurrence.id,
      status: OccurrenceStatus.open,
      nowUtc: now,
      bumpGeneratedVersion: true,
    );

    final RecurrenceScheduleVersion? version = await recur.findScheduleVersion(
      profileId.value,
      occurrence.scheduleVersionId,
    );
    final _OccurrenceDue due = version == null
        ? _OccurrenceDue(
            TaskDue.onDate(occurrence.occurrenceKey.iso),
            null,
            null,
          )
        : _dueFor(version.rule, occurrence.occurrenceKey);
    final Task updated = task.copyWith(
      due: due.due,
      status: TaskStatus.open,
      completedAtUtc: null,
      revision: task.revision + 1,
      updatedAtUtc: now,
    );
    await tasks.update(updated);

    return _write(
      resultCode: 'occurrence_undone',
      resultPayload:
          '{"task_id":"${taskId.value}",'
          '"restored":"${occurrence.occurrenceKey.iso}"}',
      profileId: profileId,
      recur: recur,
      eventType: 'occurrence_undone',
      taskId: taskId.value,
      operations: <OutboxOperationDraft>[_taskOp(updated)],
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
    }
  }

  SemanticWrite _write({
    required String resultCode,
    required String resultPayload,
    required ProfileId profileId,
    required RecurrenceWriteRepository recur,
    required String eventType,
    required String taskId,
    required List<OutboxOperationDraft> operations,
  }) {
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: eventType,
          entityType: 'task',
          entityId: taskId,
          payloadVersion: _payloadVersion,
        ),
      ],
      dirtyProjections: <DirtyProjectionDraft>[
        DirtyProjectionDraft(projection: 'search', projectionKey: taskId),
        DirtyProjectionDraft(projection: 'today', projectionKey: taskId),
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

  void _validateZone(RecurrenceRule rule) {
    if (!timeZoneResolver.supportsZone(rule.timezoneId)) {
      throw _Validation('recurrence.unknown_timezone', cause: rule.timezoneId);
    }
  }

  RecurrenceScheduleVersion _withExceptions(
    RecurrenceScheduleVersion version,
    Set<LocalDate> exceptions,
  ) => RecurrenceScheduleVersion(
    id: version.id,
    seriesId: version.seriesId,
    version: version.version,
    effectiveOccurrenceKey: version.effectiveOccurrenceKey,
    predecessorId: version.predecessorId,
    closedAtOccurrenceKey: version.closedAtOccurrenceKey,
    strategyVersion: version.strategyVersion,
    rule: version.rule.withExceptions(exceptions),
  );

  RecurrenceRule _anchorRule(RecurrenceRule rule, LocalDate start) =>
      RecurrenceRule(
        frequency: rule.frequency,
        start: start,
        timezoneId: rule.timezoneId,
        interval: rule.interval,
        byWeekdays: rule.byWeekdays,
        byMonthDays: rule.byMonthDays,
        timeOfDay: rule.timeOfDay,
        end: rule.end,
      );

  TaskDue _dueFromOccurrence(OccurrenceRecord occurrence) {
    final int? dueAt = occurrence.occurrenceDueAtUtc;
    if (dueAt != null) {
      return TaskDue.atInstant(
        utcMicros: dueAt,
        timezoneId: occurrence.occurrenceTimezone ?? 'Etc/UTC',
      );
    }
    return TaskDue.onDate(occurrence.occurrenceKey.iso);
  }

  _OccurrenceDue _dueFor(RecurrenceRule rule, LocalDate key) {
    final LocalTime? time = rule.timeOfDay;
    if (time == null) {
      return _OccurrenceDue(TaskDue.onDate(key.iso), null, null);
    }
    final ZonedInstant instant = timeZoneResolver.toInstant(
      rule.timezoneId,
      LocalDateTime(key, time),
    );
    return _OccurrenceDue(
      TaskDue.atInstant(
        utcMicros: instant.utcMicros,
        timezoneId: rule.timezoneId,
      ),
      instant.utcMicros,
      rule.timezoneId,
    );
  }

  Map<String, Object?> _ruleCanonical(RecurrenceRule rule) => <String, Object?>{
    'frequency': rule.frequency.wire,
    'interval': rule.interval,
    'start': rule.start.iso,
    'timezone': rule.timezoneId,
    if (rule.byWeekdays.isNotEmpty)
      'by_weekdays': (rule.byWeekdays.map((w) => w.wire).toList()..sort()),
    if (rule.byMonthDays.isNotEmpty)
      'by_month_days': (rule.byMonthDays.toList()..sort()),
    if (rule.timeOfDay != null) 'time_of_day': rule.timeOfDay!.secondsOfDay,
    ..._endCanonical(rule),
  };

  Map<String, Object?> _endCanonical(RecurrenceRule rule) {
    final Object end = rule.end;
    return <String, Object?>{'end': end.toString()};
  }

  OutboxOperationDraft _taskOp(Task task) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: 'task',
    entityId: task.id.value,
    opKind: 'patch',
    changedFields: 'due,recurrence_rule_id,recurrence_version,status',
    baseRowVersion: task.revision - 1,
    payload: CanonicalRequest.encode(<String, Object?>{
      'id': task.id.value,
      'due_date': task.due.dueDate,
      'due_at_utc': task.due.dueAtUtc,
      'due_timezone': task.due.timezoneId,
      'recurrence_rule_id': task.recurrenceRuleId,
      'recurrence_version': task.recurrenceVersion,
      'status': task.status.wire,
      'revision': task.revision,
    }),
  );

  OutboxOperationDraft _ruleOp(
    String versionId,
    String taskId,
    RecurrenceRule rule,
    LocalDate effectiveKey,
  ) => OutboxOperationDraft(
    operationId: idGenerator.uuidV7(),
    entityType: 'recurrence_rule',
    entityId: versionId,
    opKind: 'insert',
    payload: CanonicalRequest.encode(<String, Object?>{
      'id': versionId,
      'task_id': taskId,
      'effective_occurrence_key': effectiveKey.iso,
      ..._ruleCanonical(rule),
    }),
  );
}

/// The resolved due form for a materialized occurrence.
final class _OccurrenceDue {
  const _OccurrenceDue(this.due, this.dueAtUtc, this.timezoneId);

  final TaskDue due;
  final int? dueAtUtc;
  final String? timezoneId;
}
