import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_reconciliation.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';

/// Wiring for deletion-kernel tests over a real in-memory schema database.
///
/// Registers two trashable entities: `area` (sync-eligible, backed by
/// `life_areas`) and `tag` (sync-eligible, backed by `tags`).
final class DeletionHarness {
  DeletionHarness._(
    this.db,
    this.profileId,
    this.clock,
    this.ids,
    this.deletion,
    this.preview,
    this.reconciliation,
  );

  static Future<DeletionHarness> open({DateTime? initialUtc}) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 1, 1),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential(start: 1);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
    );
    final TrashRegistry registry = TrashRegistry(<TrashableEntity>[
      TrashableEntity(entityType: 'area', tableName: 'life_areas'),
      TrashableEntity(entityType: 'tag', tableName: 'tags'),
    ]);
    return DeletionHarness._(
      db,
      ProfileId(profileId),
      clock,
      ids,
      DeletionService(
        bus: bus,
        registry: registry,
        clock: clock,
        idGenerator: ids,
      ),
      PurgePreviewService(
        unitOfWork: unitOfWork,
        clock: clock,
        registry: registry,
      ),
      PurgeReconciliationService(
        unitOfWork: unitOfWork,
        clock: clock,
        registry: registry,
      ),
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DeletionService deletion;
  final PurgePreviewService preview;
  final PurgeReconciliationService reconciliation;

  int get nowMicros => clock.utcNow().microsecondsSinceEpoch;

  Future<void> close() => db.close();

  Future<void> insertLiveArea(String id, {required String normalizedName}) =>
      db.customStatement(
        'INSERT INTO life_areas '
        '(id, profile_id, name, normalized_name, rank, is_default, '
        'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, 0, ?, ?)',
        <Object?>[
          id,
          profileId.value,
          normalizedName,
          normalizedName,
          id,
          0,
          0,
        ],
      );

  Future<void> insertTrashedArea(
    String id, {
    required String normalizedName,
    required int deletedAtUtc,
  }) => db.customStatement(
    'INSERT INTO life_areas '
    '(id, profile_id, name, normalized_name, rank, is_default, '
    'created_at_utc, updated_at_utc, deleted_at_utc) '
    'VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)',
    <Object?>[
      id,
      profileId.value,
      normalizedName,
      normalizedName,
      id,
      0,
      0,
      deletedAtUtc,
    ],
  );

  Future<void> addOutbox({
    required String entityType,
    required String entityId,
    required String state,
    String operationId = 'op',
    String groupId = 'grp',
  }) => db.customStatement(
    'INSERT INTO outbox_mutations '
    '(operation_id, profile_id, group_id, group_index, group_count, '
    'entity_type, entity_id, op_kind, snapshot_epoch, payload, '
    'next_attempt_utc, state, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, 0, 1, ?, ?, ?, 0, ?, 0, ?, 0, 0)',
    <Object?>[
      operationId,
      profileId.value,
      groupId,
      entityType,
      entityId,
      'delete',
      '{}',
      state,
    ],
  );

  Future<void> addConflict({
    required String entityType,
    required String entityId,
    String status = 'open',
    int? retainedUntilUtc,
    String id = 'cf',
    String artifactId = 'art',
  }) => db.customStatement(
    'INSERT INTO sync_conflicts '
    '(id, profile_id, remote_artifact_id, entity_type, entity_id, fields, '
    'policy, status, retained_until_utc, created_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
    <Object?>[
      id,
      profileId.value,
      artifactId,
      entityType,
      entityId,
      'title',
      'lww',
      status,
      retainedUntilUtc,
    ],
  );

  Future<void> addFileOp({
    required String entityType,
    required String entityId,
    String state = 'pending',
    String id = 'fj',
  }) => db.customStatement(
    'INSERT INTO file_journal '
    '(id, profile_id, owner_entity_type, owner_entity_id, operation, state, '
    'attempts, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0)',
    <Object?>[id, profileId.value, entityType, entityId, 'delete', state],
  );

  Future<int> scalarInt(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data['n'] as int;
  }

  Future<int?> deletedAtOf(String table, String id) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT deleted_at_utc FROM $table WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return rows.single.data['deleted_at_utc'] as int?;
  }

  Future<bool> rowExists(String table, String id) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM $table WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.isNotEmpty;
  }
}

/// A durable command builder with deletion-flavored defaults.
DurableCommand deletionCommand({
  required ProfileId profileId,
  required String id,
  String requestHash = 'h',
  String type = 'deletion',
  String payload = '{}',
}) => DurableCommand(
  profileId: profileId,
  commandId: CommandId(id),
  commandType: type,
  schemaVersion: 1,
  requestHash: requestHash,
  canonicalPayload: payload,
);
