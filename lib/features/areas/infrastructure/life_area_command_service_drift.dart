import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/areas/application/life_area_command_service.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';
import 'package:forge/features/areas/domain/life_area.dart';
import 'package:forge/features/areas/domain/life_area_rank.dart';
import 'package:forge/features/areas/infrastructure/area_canonical_request.dart';
import 'package:forge/features/areas/infrastructure/life_area_write_repository.dart';

// Private control-flow exceptions raised inside a command body. They roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper.
final class _NotFound implements Exception {
  const _NotFound(this.areaId);
  final String areaId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed implementation of [LifeAreaCommandService] (R-GEN-002,
/// R-GEN-005). Every mutation is one atomic transaction; the receipt makes each
/// call idempotent.
final class DriftLifeAreaCommandService implements LifeAreaCommandService {
  DriftLifeAreaCommandService({
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
    required CreateLifeAreaInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create',
      'name': input.name,
      'make_default': input.makeDefault,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'life_area.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createBody(session, profileId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> rename({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
    required RenameLifeAreaInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'rename',
      'area_id': areaId.value,
      'name': input.name,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'life_area.rename',
      canonical: canonical,
      body: (TransactionSession session) =>
          _renameBody(session, profileId, areaId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> reorder({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
    required ReorderLifeAreaInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'reorder',
      'area_id': areaId.value,
      'before': input.beforeRank,
      'after': input.afterRank,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'life_area.reorder',
      canonical: canonical,
      body: (TransactionSession session) =>
          _reorderBody(session, profileId, areaId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> archive({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  }) => _run(
    profileId: profileId,
    commandId: commandId,
    commandType: 'life_area.archive',
    canonical: <String, Object?>{'op': 'archive', 'area_id': areaId.value},
    body: (TransactionSession session) =>
        _setArchivedBody(session, profileId, areaId, archive: true),
  );

  @override
  Future<Result<CommittedCommandResult>> restore({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  }) => _run(
    profileId: profileId,
    commandId: commandId,
    commandType: 'life_area.restore',
    canonical: <String, Object?>{'op': 'restore', 'area_id': areaId.value},
    body: (TransactionSession session) =>
        _setArchivedBody(session, profileId, areaId, archive: false),
  );

  @override
  Future<Result<CommittedCommandResult>> makeDefault({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  }) => _run(
    profileId: profileId,
    commandId: commandId,
    commandType: 'life_area.make_default',
    canonical: <String, Object?>{'op': 'make_default', 'area_id': areaId.value},
    body: (TransactionSession session) =>
        _makeDefaultBody(session, profileId, areaId),
  );

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createBody(
    TransactionSession session,
    ProfileId profileId,
    CreateLifeAreaInput input,
  ) async {
    final LifeAreaWriteRepository repo = session.repositories
        .resolve<LifeAreaWriteRepository>();
    final int now = _now;
    final String normalized = LifeArea.normalizeName(input.name);
    final String? clash = await repo.findIdByNormalizedName(
      profileId.value,
      normalized,
    );
    if (clash != null) {
      throw const _Validation('area.duplicate_name');
    }
    final LifeAreaRank rank = LifeAreaRank.append(
      await repo.lastRank(profileId.value),
    );
    final String areaId = idGenerator.uuidV7();
    final LifeArea area = _guardConstruct(
      () => LifeArea(
        id: LifeAreaId(areaId),
        profileId: profileId,
        name: input.name,
        rank: rank,
        isDefault: input.makeDefault,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );
    if (input.makeDefault) {
      // Clear any prior default so the single-default invariant holds.
      await repo.clearDefaultExcept(
        profileId: profileId.value,
        keepId: areaId,
        nowUtc: now,
      );
    }
    await repo.insert(area);
    return _write(
      profileId: profileId,
      repo: repo,
      resultCode: 'created',
      resultPayload: '{"id":"$areaId"}',
      eventType: 'created',
      areaId: areaId,
      opKind: 'insert',
      payload: _payload(area),
    );
  }

  Future<SemanticWrite> _renameBody(
    TransactionSession session,
    ProfileId profileId,
    LifeAreaId areaId,
    RenameLifeAreaInput input,
  ) async {
    final LifeAreaWriteRepository repo = session.repositories
        .resolve<LifeAreaWriteRepository>();
    final LifeArea? current = await repo.find(profileId.value, areaId.value);
    if (current == null) {
      throw _NotFound(areaId.value);
    }
    final String normalized = LifeArea.normalizeName(input.name);
    final String? clash = await repo.findIdByNormalizedName(
      profileId.value,
      normalized,
    );
    if (clash != null && clash != areaId.value) {
      throw const _Validation('area.duplicate_name');
    }
    final int now = _now;
    final LifeArea renamed = _guardConstruct(
      () => current.copyWith(name: input.name, updatedAtUtc: now),
    );
    await repo.update(renamed);
    return _write(
      profileId: profileId,
      repo: repo,
      resultCode: 'renamed',
      resultPayload: '{"id":"${areaId.value}"}',
      eventType: 'renamed',
      areaId: areaId.value,
      opKind: 'patch',
      payload: _payload(renamed),
    );
  }

  Future<SemanticWrite> _reorderBody(
    TransactionSession session,
    ProfileId profileId,
    LifeAreaId areaId,
    ReorderLifeAreaInput input,
  ) async {
    final LifeAreaWriteRepository repo = session.repositories
        .resolve<LifeAreaWriteRepository>();
    final LifeArea? current = await repo.find(profileId.value, areaId.value);
    if (current == null) {
      throw _NotFound(areaId.value);
    }
    final LifeAreaRank rank;
    try {
      rank = LifeAreaRank.between(
        input.beforeRank == null ? null : LifeAreaRank(input.beforeRank!),
        input.afterRank == null ? null : LifeAreaRank(input.afterRank!),
      );
    } on ArgumentError catch (e) {
      throw _Validation('area.invalid_order', cause: e.message.toString());
    }
    final int now = _now;
    final LifeArea moved = current.copyWith(rank: rank, updatedAtUtc: now);
    await repo.update(moved);
    return _write(
      profileId: profileId,
      repo: repo,
      resultCode: 'reordered',
      resultPayload: '{"id":"${areaId.value}","rank":"${rank.value}"}',
      eventType: 'reordered',
      areaId: areaId.value,
      opKind: 'patch',
      payload: _payload(moved),
    );
  }

  Future<SemanticWrite> _setArchivedBody(
    TransactionSession session,
    ProfileId profileId,
    LifeAreaId areaId, {
    required bool archive,
  }) async {
    final LifeAreaWriteRepository repo = session.repositories
        .resolve<LifeAreaWriteRepository>();
    final LifeArea? current = await repo.find(profileId.value, areaId.value);
    if (current == null) {
      throw _NotFound(areaId.value);
    }
    if (archive && current.isDefault) {
      // The default area a new aggregate inherits must always exist
      // (R-GEN-002); archiving it is rejected.
      throw const _Validation('area.default_cannot_archive');
    }
    if (archive == current.isArchived) {
      return _noop(areaId.value); // idempotent
    }
    final int now = _now;
    final LifeArea next = current.copyWith(
      archivedAtUtc: archive ? now : null,
      updatedAtUtc: now,
    );
    await repo.update(next);
    return _write(
      profileId: profileId,
      repo: repo,
      resultCode: archive ? 'archived' : 'restored',
      resultPayload: '{"id":"${areaId.value}"}',
      eventType: archive ? 'archived' : 'restored',
      areaId: areaId.value,
      opKind: 'patch',
      payload: _payload(next),
    );
  }

  Future<SemanticWrite> _makeDefaultBody(
    TransactionSession session,
    ProfileId profileId,
    LifeAreaId areaId,
  ) async {
    final LifeAreaWriteRepository repo = session.repositories
        .resolve<LifeAreaWriteRepository>();
    final LifeArea? current = await repo.find(profileId.value, areaId.value);
    if (current == null) {
      throw _NotFound(areaId.value);
    }
    if (current.isArchived) {
      throw const _Validation('area.archived_cannot_default');
    }
    if (current.isDefault) {
      return _noop(areaId.value); // idempotent
    }
    final int now = _now;
    await repo.clearDefaultExcept(
      profileId: profileId.value,
      keepId: areaId.value,
      nowUtc: now,
    );
    final LifeArea next = current.copyWith(isDefault: true, updatedAtUtc: now);
    await repo.update(next);
    return _write(
      profileId: profileId,
      repo: repo,
      resultCode: 'default_set',
      resultPayload: '{"id":"${areaId.value}"}',
      eventType: 'default_set',
      areaId: areaId.value,
      opKind: 'patch',
      payload: _payload(next),
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
    final String payload = AreaCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: AreaCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'area.not_found',
          safeMessageKey: 'error.area.not_found',
          retryable: false,
          redactedCause: e.areaId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.area.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  Future<SemanticWrite> _write({
    required ProfileId profileId,
    required LifeAreaWriteRepository repo,
    required String resultCode,
    required String resultPayload,
    required String eventType,
    required String areaId,
    required String opKind,
    required String payload,
  }) async {
    final int epoch = await repo.currentEpoch(profileId.value);
    return SemanticWrite(
      resultCode: resultCode,
      payloadVersion: _payloadVersion,
      resultPayload: resultPayload,
      activity: <ActivityDraft>[
        ActivityDraft(
          id: idGenerator.uuidV7(),
          eventType: eventType,
          entityType: 'life_area',
          entityId: areaId,
          payloadVersion: _payloadVersion,
        ),
      ],
      outboxGroup: OutboxGroupDraft(
        groupId: idGenerator.uuidV7(),
        snapshotEpoch: epoch,
        operations: <OutboxOperationDraft>[
          OutboxOperationDraft(
            operationId: idGenerator.uuidV7(),
            entityType: 'life_area',
            entityId: areaId,
            opKind: opKind,
            payload: payload,
          ),
        ],
      ),
    );
  }

  SemanticWrite _noop(String areaId) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$areaId"}',
  );

  LifeArea _guardConstruct(LifeArea Function() build) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation('area.invalid_field', cause: e.message);
    }
  }

  String _payload(LifeArea area) =>
      AreaCanonicalRequest.encode(<String, Object?>{
        'id': area.id.value,
        'name': area.name,
        'normalized_name': area.normalizedName,
        'rank': area.rank.value,
        'is_default': area.isDefault,
        'archived_at_utc': area.archivedAtUtc,
      });
}
