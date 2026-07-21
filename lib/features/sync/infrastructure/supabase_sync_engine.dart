/// The client-side push/pull engine that drives the replaceable
/// [SyncTransport] against the local outbox and the typed remote appliers
/// (R-SYNC-002, R-SYNC-003; design.md §8/§9).
///
/// * [pushPending] reads ready semantic groups from the transactional outbox,
///   reconstructs each as a wire group through the manifest/identity boundary
///   ([PushEnvelopeBuilder]), pushes it, and advances the outbox + journal via
///   the [SyncAcknowledgementService] for accepted/conflict groups. A stale
///   epoch surfaces so the host can bootstrap.
/// * [pullToHead] reads the durable cursor, pulls contiguous pages, translates
///   and applies each through the atomic [PullApplyCoordinator], and advances
///   the cursor — until the server has no more or a bootstrap is required.
///
/// The engine owns no timers/sockets; the host (or [SyncScheduler]) decides
/// when to call it. It is transport-agnostic — any protocol-v2 backend works.
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/app/infrastructure/database/sync/acknowledgement_service.dart';
import 'package:forge/app/infrastructure/database/sync/pull_apply_coordinator.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/field_version.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// The aggregate outcome of one sync run.
final class SyncRunReport {
  const SyncRunReport({
    required this.pushedGroups,
    required this.acceptedGroups,
    required this.conflictGroups,
    required this.rejectedGroups,
    required this.pulledPages,
    required this.appliedChanges,
    required this.staleEpoch,
    required this.bootstrapRequired,
  });

  final int pushedGroups;
  final int acceptedGroups;
  final int conflictGroups;
  final int rejectedGroups;
  final int pulledPages;
  final int appliedChanges;

  /// True when a push was rejected because the device epoch is stale; the host
  /// must bootstrap before syncing again.
  final bool staleEpoch;

  /// True when a pull page required a bootstrap (epoch change / gap).
  final bool bootstrapRequired;

  bool get needsBootstrap => staleEpoch || bootstrapRequired;
}

/// Drives push and pull for one linked profile over a [SyncTransport].
final class SupabaseSyncEngine {
  SupabaseSyncEngine({
    required UnitOfWork unitOfWork,
    required SyncTransport transport,
    required PullApplyCoordinator pullApply,
    required SyncAcknowledgementService acknowledgements,
    required PushEnvelopeBuilder envelopeBuilder,
    required PullTranslator pullTranslator,
    required Clock clock,
    required ProfileId profileId,
    required DeviceId deviceId,
    String backend = 'supabase',
  }) : _unitOfWork = unitOfWork,
       _transport = transport,
       _pullApply = pullApply,
       _acks = acknowledgements,
       _envelopeBuilder = envelopeBuilder,
       _pullTranslator = pullTranslator,
       _clock = clock,
       _profileId = profileId,
       _deviceId = deviceId,
       _backend = backend;

  final UnitOfWork _unitOfWork;
  final SyncTransport _transport;
  final PullApplyCoordinator _pullApply;
  final SyncAcknowledgementService _acks;
  final PushEnvelopeBuilder _envelopeBuilder;
  final PullTranslator _pullTranslator;
  final Clock _clock;
  final ProfileId _profileId;
  final DeviceId _deviceId;
  final String _backend;

  /// The maximum contiguous pull pages fetched in one [pullToHead] call, a
  /// guard against an unexpectedly long feed monopolising one run.
  static const int _maxPagesPerRun = 64;

  /// Pushes then pulls once, returning the aggregate outcome.
  Future<SyncRunReport> syncNow() async {
    final PushSummary push = await pushPending();
    final PullSummary pull = await pullToHead();
    return SyncRunReport(
      pushedGroups: push.pushed,
      acceptedGroups: push.accepted,
      conflictGroups: push.conflict,
      rejectedGroups: push.rejected,
      pulledPages: pull.pages,
      appliedChanges: pull.appliedChanges,
      staleEpoch: push.staleEpoch,
      bootstrapRequired: pull.bootstrapRequired,
    );
  }

  /// Pushes every ready outbox group, one group per batch.
  Future<PushSummary> pushPending() async {
    final int now = _clock.utcNow().microsecondsSinceEpoch;
    final List<String> groupIds = await _unitOfWork.transaction<List<String>>((
      TransactionSession session,
    ) {
      return session.repositories.resolve<OutboxRepository>().readyGroups(
        _profileId.value,
        now,
      );
    });

    int pushed = 0;
    int accepted = 0;
    int conflict = 0;
    int rejected = 0;
    bool staleEpoch = false;

    for (final String groupId in groupIds) {
      final List<OutboxPushOperation> ops = await _unitOfWork
          .transaction<List<OutboxPushOperation>>((TransactionSession session) {
            return session.repositories
                .resolve<OutboxRepository>()
                .groupPushOperations(_profileId.value, groupId);
          });
      if (ops.isEmpty) {
        continue;
      }
      final int epoch = ops.first.snapshotEpoch;
      final SemanticGroup group = _rebuildGroup(groupId, epoch, ops);
      final PushBatch batch = _envelopeBuilder.build(
        localProfileId: _profileId,
        deviceId: _deviceId.value,
        epoch: SnapshotEpoch(epoch),
        groups: <SemanticGroup>[group],
      );

      await _acks.beginSend(_profileId, groupId);
      final PushResponse response = await _transport.push(batch);
      pushed += 1;

      if (response.staleEpoch) {
        staleEpoch = true;
        // Leave the group pending; a bootstrap will rebase it.
        continue;
      }
      for (final SemanticGroupResult result in response.results) {
        switch (result.outcome) {
          case SemanticGroupOutcome.accepted:
            accepted += 1;
            await _acks.acknowledgeAccepted(_profileId, result.groupId);
          case SemanticGroupOutcome.conflict:
            conflict += 1;
            await _acks.acknowledgeConflict(_profileId, result.groupId);
          case SemanticGroupOutcome.rejected:
            rejected += 1;
          case SemanticGroupOutcome.staleEpoch:
            staleEpoch = true;
        }
      }
    }

    return PushSummary(
      pushed: pushed,
      accepted: accepted,
      conflict: conflict,
      rejected: rejected,
      staleEpoch: staleEpoch,
    );
  }

  /// Pulls and applies contiguous pages until the server has no more or a
  /// bootstrap is required.
  Future<PullSummary> pullToHead() async {
    int pages = 0;
    int appliedChanges = 0;
    bool bootstrapRequired = false;

    for (int i = 0; i < _maxPagesPerRun; i += 1) {
      final SyncCursor cursor = await _readCursor();
      final PullPage page = await _transport.pull(cursor);
      final TranslatedPullPage translated = _pullTranslator.translate(
        page: page,
        cursor: cursor,
      );
      final PullApplyResult result = await _pullApply.applyPage(
        PullApplyRequest(page: translated, backend: _backend),
      );
      pages += 1;
      appliedChanges += result.appliedChangeCount;
      if (result.outcome == PullApplyOutcome.bootstrapRequired) {
        bootstrapRequired = true;
        break;
      }
      if (!page.hasMore) {
        break;
      }
    }

    return PullSummary(
      pages: pages,
      appliedChanges: appliedChanges,
      bootstrapRequired: bootstrapRequired,
    );
  }

  Future<SyncCursor> _readCursor() {
    return _unitOfWork.transaction<SyncCursor>((
      TransactionSession session,
    ) async {
      final SyncCursor? stored = await session.repositories
          .resolve<SyncCursorRepository>()
          .read(_profileId.value, _backend);
      return stored ?? SyncCursor.initial();
    });
  }

  SemanticGroup _rebuildGroup(
    String groupId,
    int epoch,
    List<OutboxPushOperation> ops,
  ) {
    final List<SyncOperation> operations = <SyncOperation>[];
    for (final OutboxPushOperation op in ops) {
      operations.add(
        SyncOperation(
          operationId: op.operationId,
          index: op.groupIndex,
          entityType: op.entityType,
          entityId: op.entityId,
          kind: SyncOperationKind.fromWire(op.opKind),
          payload: _decodePayload(op.payload),
          changedFields: _decodeChangedFields(op.changedFields),
          baseRowVersion: op.baseRowVersion,
          baseFieldVersions: _decodeBaseFieldVersions(op.baseFieldVersions),
        ),
      );
    }
    return SemanticGroup(
      groupId: groupId,
      snapshotEpoch: epoch,
      operations: operations,
    );
  }

  static Map<String, Object?> _decodePayload(String payload) {
    if (payload.isEmpty) {
      return <String, Object?>{};
    }
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map) {
      return decoded.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    return <String, Object?>{};
  }

  static List<String> _decodeChangedFields(String? changedFields) {
    if (changedFields == null || changedFields.isEmpty) {
      return const <String>[];
    }
    final Object? decoded = jsonDecode(changedFields);
    if (decoded is List) {
      return decoded.map((Object? e) => e.toString()).toList(growable: false);
    }
    return const <String>[];
  }

  static FieldVersionMap? _decodeBaseFieldVersions(String? baseFieldVersions) {
    if (baseFieldVersions == null || baseFieldVersions.isEmpty) {
      return null;
    }
    final Object? decoded = jsonDecode(baseFieldVersions);
    if (decoded is! Map) {
      return null;
    }
    final Map<String, FieldVersion> versions = <String, FieldVersion>{};
    decoded.forEach((Object? field, Object? value) {
      final int version = value is int
          ? value
          : (value is Map && value['version'] is int
                ? value['version'] as int
                : int.tryParse('$value') ?? 0);
      final String lastOp = value is Map && value['last_operation_id'] is String
          ? value['last_operation_id'] as String
          : '';
      versions[field.toString()] = FieldVersion(
        version: version,
        lastOperationId: lastOp,
      );
    });
    return FieldVersionMap(versions);
  }
}

final class PushSummary {
  const PushSummary({
    required this.pushed,
    required this.accepted,
    required this.conflict,
    required this.rejected,
    required this.staleEpoch,
  });

  final int pushed;
  final int accepted;
  final int conflict;
  final int rejected;
  final bool staleEpoch;
}

final class PullSummary {
  const PullSummary({
    required this.pages,
    required this.appliedChanges,
    required this.bootstrapRequired,
  });

  final int pages;
  final int appliedChanges;
  final bool bootstrapRequired;
}
