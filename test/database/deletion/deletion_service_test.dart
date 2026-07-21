import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/core/domain/result.dart';

import 'deletion_test_support.dart';

/// Soft deletion, reversible Undo/restore, and their atomic bulk variants over
/// a real Drift database.
///
/// **Validates: Requirements R-GEN-003, NFR-UX-002**
void main() {
  late DeletionHarness h;

  setUp(() async {
    h = await DeletionHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given a live row when it is soft-deleted', () {
    test('then it is tombstoned, not removed, and Undo is available', () async {
      await h.insertLiveArea('area-1', normalizedName: 'career');
      final Result<CommittedCommandResult> result = await h.deletion.softDelete(
        command: deletionCommand(profileId: h.profileId, id: 'c1'),
        ref: const EntityRef(entityType: 'area', entityId: 'area-1'),
      );

      expect(result.valueOrNull, isNotNull);
      expect(result.valueOrNull!.resultCode, 'soft_deleted');
      // The row survives with a tombstone; nothing is destroyed.
      expect(await h.rowExists('life_areas', 'area-1'), isTrue);
      expect(await h.deletedAtOf('life_areas', 'area-1'), h.nowMicros);
      // An activity event and a durable receipt were committed.
      expect(
        await h.scalarInt(
          "SELECT COUNT(*) AS n FROM activity_events "
          "WHERE event_type = 'soft_deleted'",
        ),
        1,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        1,
      );
    });

    test(
      'then a sync-eligible entity enqueues a tombstone outbox op',
      () async {
        await h.insertLiveArea('area-1', normalizedName: 'career');
        await h.deletion.softDelete(
          command: deletionCommand(profileId: h.profileId, id: 'c1'),
          ref: const EntityRef(entityType: 'area', entityId: 'area-1'),
        );
        expect(
          await h.scalarInt(
            "SELECT COUNT(*) AS n FROM outbox_mutations "
            "WHERE entity_id = 'area-1' AND op_kind = 'delete'",
          ),
          1,
        );
        expect(
          await h.scalarInt(
            'SELECT COUNT(*) AS n FROM pending_command_journal',
          ),
          1,
        );
      },
    );
  });

  group('given a soft-deleted row when it is restored', () {
    test('then the tombstone clears while the id and links are '
        'preserved', () async {
      await h.insertLiveArea('area-1', normalizedName: 'career');
      await h.deletion.softDelete(
        command: deletionCommand(profileId: h.profileId, id: 'c1'),
        ref: const EntityRef(entityType: 'area', entityId: 'area-1'),
      );
      final Result<CommittedCommandResult> restored = await h.deletion.restore(
        command: deletionCommand(profileId: h.profileId, id: 'c2'),
        ref: const EntityRef(entityType: 'area', entityId: 'area-1'),
      );
      expect(restored.valueOrNull!.resultCode, 'restored');
      expect(await h.rowExists('life_areas', 'area-1'), isTrue);
      expect(await h.deletedAtOf('life_areas', 'area-1'), isNull);
    });
  });

  group('given a missing row when it is soft-deleted', () {
    test('then it fails validation without writing anything', () async {
      final Result<CommittedCommandResult> result = await h.deletion.softDelete(
        command: deletionCommand(profileId: h.profileId, id: 'c1'),
        ref: const EntityRef(entityType: 'area', entityId: 'ghost'),
      );
      expect(result.failureOrNull?.kind, FailureKind.validation);
      expect(result.failureOrNull?.code, 'deletion.entity_missing');
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM command_receipts'),
        0,
      );
    });
  });

  group('given an already soft-deleted row when it is deleted again', () {
    test('then the repeated delete is an idempotent no-op', () async {
      await h.insertTrashedArea(
        'area-1',
        normalizedName: 'career',
        deletedAtUtc: 5,
      );
      final Result<CommittedCommandResult> result = await h.deletion.softDelete(
        command: deletionCommand(profileId: h.profileId, id: 'c1'),
        ref: const EntityRef(entityType: 'area', entityId: 'area-1'),
      );
      expect(result.valueOrNull!.resultCode, 'noop');
      // The original tombstone instant is untouched and no outbox op appears.
      expect(await h.deletedAtOf('life_areas', 'area-1'), 5);
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        0,
      );
    });
  });

  group('given a bulk soft-delete when several live rows are targeted', () {
    test('then all are tombstoned in one atomic semantic group', () async {
      await h.insertLiveArea('area-1', normalizedName: 'career');
      await h.insertLiveArea('area-2', normalizedName: 'health');
      final Result<CommittedCommandResult> result = await h.deletion
          .softDeleteBulk(
            command: deletionCommand(profileId: h.profileId, id: 'c1'),
            refs: const <EntityRef>[
              EntityRef(entityType: 'area', entityId: 'area-1'),
              EntityRef(entityType: 'area', entityId: 'area-2'),
            ],
          );
      expect(result.valueOrNull!.resultPayload, '{"affected":2}');
      expect(await h.deletedAtOf('life_areas', 'area-1'), isNotNull);
      expect(await h.deletedAtOf('life_areas', 'area-2'), isNotNull);
      // One group, two ordered operations.
      expect(
        await h.scalarInt(
          'SELECT COUNT(DISTINCT group_id) AS n FROM outbox_mutations',
        ),
        1,
      );
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        2,
      );
    });
  });

  group('given a bulk delete preview when live and trashed rows mix', () {
    test('then only the live rows are reported as affected', () async {
      await h.insertLiveArea('area-1', normalizedName: 'career');
      await h.insertTrashedArea(
        'area-2',
        normalizedName: 'health',
        deletedAtUtc: 5,
      );
      final BulkOperationPreview preview = await h.preview
          .previewBulkDelete(h.profileId, const <EntityRef>[
            EntityRef(entityType: 'area', entityId: 'area-1'),
            EntityRef(entityType: 'area', entityId: 'area-2'),
          ]);
      expect(preview.affectedCount, 1);
      expect(preview.refs.single.entityId, 'area-1');
    });
  });
}
