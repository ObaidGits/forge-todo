import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notifications/application/reminder_command_service.dart';
import 'package:forge/features/notifications/application/reminder_commands.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/infrastructure/reminder_canonical_request.dart';
import 'package:forge/features/notifications/infrastructure/reminder_mapper.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repositories.dart';

/// Private control-flow exceptions raised inside a command body; the outer
/// wrapper maps them to a stable [Failure] and rolls the transaction back.
final class _ReminderNotFound implements Exception {
  const _ReminderNotFound(this.reminderId);
  final String reminderId;
}

final class _ReminderValidation implements Exception {
  const _ReminderValidation(this.code);
  final String code;
}

/// Command-bus-backed [ReminderCommandService] (R-NOTIFY-001/005, R-GEN-005).
///
/// Every mutation is one atomic transaction that writes the reminder row, an
/// activity event, and a sync-eligible outbox group before returning the stable
/// committed result. Notification actions persist locally here *before* any OS
/// dismissal happens (R-NOTIFY-005).
final class DriftReminderCommandService implements ReminderCommandService {
  DriftReminderCommandService({
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
    required ReminderId reminderId,
    required CreateReminderInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create',
      'reminder_id': reminderId.value,
      'owner_type': input.ownerType.wire,
      'owner_id': input.ownerId,
      'category':
          (input.category ?? ReminderCategory.forOwner(input.ownerType)).wire,
      'trigger_kind': input.triggerKind.name,
      'absolute_local': input.absoluteLocal?.iso,
      'offset_minutes': input.offsetMinutes,
      'timezone_id': input.timezoneId,
      'dst_policy': ReminderMapper.dstPolicyWire(input.dstPolicy),
      'enabled': input.enabled,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'reminder.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createBody(session, profileId, reminderId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setEnabled({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required bool enabled,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_enabled',
      'reminder_id': reminderId.value,
      'enabled': enabled,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'reminder.set_enabled',
      canonical: canonical,
      body: (TransactionSession session) =>
          _setEnabledBody(session, profileId, reminderId, enabled),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> delete({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'delete',
      'reminder_id': reminderId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'reminder.delete',
      canonical: canonical,
      body: (TransactionSession session) =>
          _deleteBody(session, profileId, reminderId),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> applyAction({
    required CommandId commandId,
    required ProfileId profileId,
    required ReminderId reminderId,
    required ReminderAction action,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'action',
      'reminder_id': reminderId.value,
      'action': action.wire,
      'snooze_minutes': action.snoozeMinutes,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'reminder.action',
      canonical: canonical,
      body: (TransactionSession session) =>
          _actionBody(session, profileId, reminderId, action),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createBody(
    TransactionSession session,
    ProfileId profileId,
    ReminderId reminderId,
    CreateReminderInput input,
  ) async {
    final ReminderWriteRepository repo = session.repositories
        .resolve<ReminderWriteRepository>();
    _validateCreate(input);
    final int now = _now;
    final ReminderTrigger trigger =
        input.triggerKind == ReminderTriggerKind.absolute
        ? AbsoluteLocalTrigger(local: input.absoluteLocal!)
        : OffsetTrigger(offsetMinutes: input.offsetMinutes!);
    final Reminder reminder = Reminder(
      id: reminderId,
      profileId: profileId,
      ownerType: input.ownerType,
      ownerId: input.ownerId,
      category: input.category ?? ReminderCategory.forOwner(input.ownerType),
      trigger: trigger,
      timezoneId: input.timezoneId,
      dstPolicy: input.dstPolicy,
      enabled: input.enabled,
      deliveryStatus: ReminderDeliveryStatus.pending,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repo.insert(reminder);
    return _write(
      resultCode: 'created',
      reminderId: reminderId.value,
      event: 'reminder_created',
      epoch: await repo.currentEpoch(profileId.value),
      opKind: 'insert',
    );
  }

  Future<SemanticWrite> _setEnabledBody(
    TransactionSession session,
    ProfileId profileId,
    ReminderId reminderId,
    bool enabled,
  ) async {
    final ReminderWriteRepository repo = session.repositories
        .resolve<ReminderWriteRepository>();
    final Reminder current = await _require(repo, profileId, reminderId);
    if (current.enabled == enabled) {
      return _noop(reminderId.value);
    }
    final int now = _now;
    await repo.update(
      current.copyWith(
        enabled: enabled,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    return _write(
      resultCode: enabled ? 'enabled' : 'disabled',
      reminderId: reminderId.value,
      event: enabled ? 'reminder_enabled' : 'reminder_disabled',
      epoch: await repo.currentEpoch(profileId.value),
      opKind: 'patch',
      baseRowVersion: current.revision,
    );
  }

  Future<SemanticWrite> _deleteBody(
    TransactionSession session,
    ProfileId profileId,
    ReminderId reminderId,
  ) async {
    final ReminderWriteRepository repo = session.repositories
        .resolve<ReminderWriteRepository>();
    final Reminder current = await _require(repo, profileId, reminderId);
    if (current.isDeleted) {
      return _noop(reminderId.value);
    }
    final int now = _now;
    await repo.update(
      current.copyWith(
        enabled: false,
        deletedAtUtc: now,
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    return _write(
      resultCode: 'deleted',
      reminderId: reminderId.value,
      event: 'reminder_deleted',
      epoch: await repo.currentEpoch(profileId.value),
      opKind: 'delete',
      baseRowVersion: current.revision,
    );
  }

  Future<SemanticWrite> _actionBody(
    TransactionSession session,
    ProfileId profileId,
    ReminderId reminderId,
    ReminderAction action,
  ) async {
    final ReminderWriteRepository repo = session.repositories
        .resolve<ReminderWriteRepository>();
    final Reminder current = await _require(repo, profileId, reminderId);
    final int now = _now;
    final Reminder next;
    final String event;
    switch (action.kind) {
      case ReminderActionKind.snooze:
        next = current.copyWith(
          snoozedUntilUtc:
              now + action.snoozeMinutes! * Duration.microsecondsPerMinute,
          deliveryStatus: ReminderDeliveryStatus.pending,
          revision: current.revision + 1,
          updatedAtUtc: now,
        );
        event = 'reminder_snoozed';
      case ReminderActionKind.dismiss:
      case ReminderActionKind.complete:
        // The owner-side completion (if any) is committed by the owner feature
        // command; here we durably acknowledge the notification so it is safe
        // to dismiss (R-NOTIFY-005).
        next = current.copyWith(
          snoozedUntilUtc: null,
          deliveryStatus: ReminderDeliveryStatus.skipped,
          revision: current.revision + 1,
          updatedAtUtc: now,
        );
        event = action.kind == ReminderActionKind.complete
            ? 'reminder_completed'
            : 'reminder_dismissed';
    }
    await repo.update(next);
    return _write(
      resultCode: action.wire,
      reminderId: reminderId.value,
      event: event,
      epoch: await repo.currentEpoch(profileId.value),
      opKind: 'patch',
      baseRowVersion: current.revision,
    );
  }

  // ---- helpers ------------------------------------------------------------

  void _validateCreate(CreateReminderInput input) {
    final bool absolute = input.triggerKind == ReminderTriggerKind.absolute;
    if (absolute && input.absoluteLocal == null) {
      throw const _ReminderValidation('reminder.absolute_requires_local');
    }
    if (!absolute && input.offsetMinutes == null) {
      throw const _ReminderValidation('reminder.offset_requires_minutes');
    }
    if (absolute && input.offsetMinutes != null) {
      throw const _ReminderValidation('reminder.trigger_conflict');
    }
    if (!absolute && input.absoluteLocal != null) {
      throw const _ReminderValidation('reminder.trigger_conflict');
    }
    if (input.timezoneId.isEmpty) {
      throw const _ReminderValidation('reminder.timezone_required');
    }
    if (input.ownerId.isEmpty) {
      throw const _ReminderValidation('reminder.owner_required');
    }
  }

  Future<Reminder> _require(
    ReminderWriteRepository repo,
    ProfileId profileId,
    ReminderId reminderId,
  ) async {
    final Reminder? current = await repo.find(
      profileId.value,
      reminderId.value,
    );
    if (current == null) {
      throw _ReminderNotFound(reminderId.value);
    }
    return current;
  }

  SemanticWrite _write({
    required String resultCode,
    required String reminderId,
    required String event,
    required int epoch,
    required String opKind,
    int? baseRowVersion,
  }) {
    final String payload = ReminderCanonicalRequest.encode(<String, Object?>{
      'id': reminderId,
    });
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"$reminderId"}',
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: event,
          entityType: 'reminder',
          entityId: reminderId,
          payloadVersion: _payloadVersion,
        ),
      ],
      outboxGroup: OutboxGroupDraft(
        groupId: idGenerator.uuidV7(),
        snapshotEpoch: epoch,
        operations: <OutboxOperationDraft>[
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: 'reminder',
            entityId: reminderId,
            opKind: opKind,
            baseRowVersion: baseRowVersion,
            payload: payload,
          ),
        ],
      ),
      afterCommitHints: <AfterCommitHint>[
        AfterCommitHint(
          kind: 'reminder',
          entityType: 'reminder',
          entityId: reminderId,
        ),
      ],
    );
  }

  SemanticWrite _noop(String reminderId) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$reminderId"}',
  );

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = ReminderCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: ReminderCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _ReminderNotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'reminder.not_found',
          safeMessageKey: 'error.reminder.not_found',
          retryable: false,
          redactedCause: e.reminderId,
        ),
      );
    } on _ReminderValidation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.reminder.invalid',
          retryable: false,
        ),
      );
    }
  }
}
