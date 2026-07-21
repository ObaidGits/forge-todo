import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_reconciliation.dart';
import 'package:forge/core/domain/result.dart';

import 'deletion_test_support.dart';

/// Purge-eligibility reporting, previewed/confirmed hard purge, hard-purge
/// blocks, and idempotent replay over a real Drift database.
///
/// **Validates: Requirements R-GEN-003, NFR-UX-002**
void main() {
  late DeletionHarness h;

  const EntityRef areaRef = EntityRef(entityType: 'area', entityId: 'area-1');

  setUp(() async {
    h = await DeletionHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Future<void> seedTrashed({int deletedAtUtc = 5}) => h.insertTrashedArea(
    'area-1',
    normalizedName: 'career',
    deletedAtUtc: deletedAtUtc,
  );

  group('given a soft-deleted row with no obligations', () {
    test('when previewed then it is purgeable and unblocked', () async {
      await seedTrashed();
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.affectedCount, 1);
      expect(preview.blockedCount, 0);
      expect(preview.targets.single.purgeable, isTrue);
    });

    test('when purged with the matching confirmation then the row is '
        'permanently removed', () async {
      await seedTrashed();
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      final Result<CommittedCommandResult> result = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      expect(result.valueOrNull!.resultCode, 'purged');
      expect(await h.rowExists('life_areas', 'area-1'), isFalse);
      // Hard purge is local storage reclamation: it enqueues no outbox work.
      expect(
        await h.scalarInt('SELECT COUNT(*) AS n FROM outbox_mutations'),
        0,
      );
    });
  });

  group('given a hard purge without a valid confirmation', () {
    test('when the confirmation does not match then it is rejected and '
        'nothing is removed', () async {
      await seedTrashed();
      final Result<CommittedCommandResult> result = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: const PurgeConfirmation('bogus'),
      );
      expect(result.failureOrNull?.kind, FailureKind.validation);
      expect(result.failureOrNull?.code, 'purge.confirmation_mismatch');
      expect(await h.rowExists('life_areas', 'area-1'), isTrue);
    });
  });

  group('given hard-purge blocks', () {
    test('when a pending outbox op exists then purge is blocked', () async {
      await seedTrashed();
      await h.addOutbox(
        entityType: 'area',
        entityId: 'area-1',
        state: 'pending',
      );
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.affectedCount, 0);
      expect(preview.hasBlocked, isTrue);
      expect(preview.targets.single.blocks.reasons, contains('pending_outbox'));

      final Result<CommittedCommandResult> result = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      expect(result.failureOrNull?.kind, FailureKind.conflict);
      expect(result.failureOrNull?.code, 'purge.blocked');
      expect(await h.rowExists('life_areas', 'area-1'), isTrue);
    });

    test('when an open conflict exists then purge is blocked', () async {
      await seedTrashed();
      await h.addConflict(entityType: 'area', entityId: 'area-1');
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.targets.single.blocks.reasons, contains('open_conflict'));
      expect(preview.affectedCount, 0);
    });

    test('when unexpired remote retention exists then purge is '
        'blocked', () async {
      await seedTrashed();
      // An accepted-but-unpruned tombstone still retained in the outbox.
      await h.addOutbox(
        entityType: 'area',
        entityId: 'area-1',
        state: 'acknowledged',
      );
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(
        preview.targets.single.blocks.reasons,
        contains('remote_retention'),
      );
      expect(preview.affectedCount, 0);
    });

    test('when a conflict artifact is still within retention then purge is '
        'blocked', () async {
      await seedTrashed();
      await h.addConflict(
        entityType: 'area',
        entityId: 'area-1',
        status: 'resolved',
        retainedUntilUtc: h.nowMicros + 1000,
      );
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(
        preview.targets.single.blocks.reasons,
        contains('remote_retention'),
      );
    });

    test('when an in-flight file operation exists then purge is '
        'blocked', () async {
      await seedTrashed();
      await h.addFileOp(entityType: 'area', entityId: 'area-1');
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.targets.single.blocks.reasons, contains('file_operation'));
      expect(preview.affectedCount, 0);
    });

    test('when a block is cleared then purge proceeds', () async {
      await seedTrashed();
      await h.addFileOp(entityType: 'area', entityId: 'area-1', state: 'done');
      // A terminal file op is not a block.
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.affectedCount, 1);
      final Result<CommittedCommandResult> result = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      expect(result.valueOrNull!.resultCode, 'purged');
      expect(await h.rowExists('life_areas', 'area-1'), isFalse);
    });
  });

  group('given a completed hard purge when it is replayed', () {
    test('then the same command id returns the stored result '
        'idempotently', () async {
      await seedTrashed();
      final PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      final Result<CommittedCommandResult> first = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      final Result<CommittedCommandResult> replay = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      expect(first.valueOrNull!.replayed, isFalse);
      expect(replay.valueOrNull!.replayed, isTrue);
      expect(replay.valueOrNull!.commitSeq, first.valueOrNull!.commitSeq);
      // Purge happened exactly once.
      expect(
        await h.scalarInt(
          "SELECT COUNT(*) AS n FROM activity_events "
          "WHERE event_type = 'purged'",
        ),
        1,
      );
    });
  });

  group('given the full soft-delete lifecycle', () {
    test('when the tombstone is unsynced then purge is blocked, and once its '
        'outbox is pruned purge proceeds', () async {
      await h.insertLiveArea('area-1', normalizedName: 'career');
      // Soft delete enqueues a pending tombstone -> purge blocked.
      await h.deletion.softDelete(
        command: deletionCommand(profileId: h.profileId, id: 'c1'),
        ref: areaRef,
      );
      PurgePreview preview = await h.preview.previewPurge(
        h.profileId,
        <EntityRef>[areaRef],
      );
      expect(preview.affectedCount, 0);
      expect(preview.hasBlocked, isTrue);

      // Simulate sync acceptance + journaled pruning clearing the outbox.
      await h.db.customStatement('DELETE FROM outbox_mutations');
      preview = await h.preview.previewPurge(h.profileId, <EntityRef>[areaRef]);
      expect(preview.affectedCount, 1);

      final Result<CommittedCommandResult> purged = await h.deletion.hardPurge(
        command: deletionCommand(profileId: h.profileId, id: 'p1'),
        refs: const <EntityRef>[areaRef],
        confirmation: preview.confirmation,
      );
      expect(purged.valueOrNull!.resultCode, 'purged');
      expect(await h.rowExists('life_areas', 'area-1'), isFalse);
    });
  });

  group('given automatic reconciliation', () {
    test('when trash retention has elapsed then rows are reported eligible '
        'without being purged', () async {
      final int oldDelete =
          h.nowMicros - const Duration(days: 31).inMicroseconds;
      final int recentDelete =
          h.nowMicros - const Duration(days: 5).inMicroseconds;
      await h.insertTrashedArea(
        'area-old',
        normalizedName: 'career',
        deletedAtUtc: oldDelete,
      );
      await h.insertTrashedArea(
        'area-new',
        normalizedName: 'health',
        deletedAtUtc: recentDelete,
      );

      final PurgeEligibilityReport report = await h.reconciliation.report(
        h.profileId,
      );
      expect(report.eligibleCount, 1);
      expect(report.eligible.single.entityId, 'area-old');
      // Reporting is non-destructive: both rows still exist.
      expect(await h.rowExists('life_areas', 'area-old'), isTrue);
      expect(await h.rowExists('life_areas', 'area-new'), isTrue);
    });
  });
}
