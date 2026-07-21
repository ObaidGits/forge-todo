/// Durable, pullable, idempotent conflict-artifact persistence via the
/// `sync_conflicts` table (task 9.3; R-SYNC-004, R-NOTE-007, data-model.md §6).
///
/// Proves an artifact survives as a recoverable record, that re-recording the
/// same artifact does not duplicate it, and that resolution is idempotent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/repositories/sync_write_repositories.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';

import '../schema/schema_test_database.dart';

ConflictArtifact _artifact({
  String id = 'artifact-1',
  ConflictStatus status = ConflictStatus.open,
  int? resolvedAtUtc,
  String? resolution,
}) => ConflictArtifact(
  remoteArtifactId: id,
  entityType: 'note',
  entityId: 'note-1',
  policy: ConflictPolicyKind.noteConflictCopy,
  fields: const <String>['body'],
  createdAtUtc: 10,
  baseSnapshot: const <String, Object?>{'body': 'base'},
  localSnapshot: const <String, Object?>{'body': 'local losing'},
  remoteSnapshot: const <String, Object?>{'body': 'remote winning'},
  status: status,
  resolution: resolution,
  resolvedAtUtc: resolvedAtUtc,
);

void main() {
  late ForgeSchemaDatabase db;
  late DriftUnitOfWork unitOfWork;
  late String profileId;

  setUp(() async {
    db = openSchemaDatabase();
    profileId = await insertProfile(db);
    unitOfWork = DriftUnitOfWork(db, activeProfileResolver: () => profileId);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    '[TEST-DB-SYNC-CONFLICT-DURABLE][V1][TASK-9.3][R-SYNC-004,R-NOTE-007] '
    'a recorded artifact is durable and its losing value is recoverable',
    () async {
      await unitOfWork.transaction<void>((TransactionSession session) async {
        await session.repositories
            .resolve<SyncConflictRepository>()
            .upsertArtifact(
              profileId: profileId,
              id: 'local-pk-1',
              artifact: _artifact(),
            );
      });

      await unitOfWork.transaction<void>((TransactionSession session) async {
        final SyncConflictRepository repo = session.repositories
            .resolve<SyncConflictRepository>();
        final ConflictArtifact? found = await repo.findByArtifactId(
          profileId,
          'artifact-1',
        );
        expect(found, isNotNull);
        expect(found!.policy, ConflictPolicyKind.noteConflictCopy);
        expect(found.localSnapshot!['body'], 'local losing');
        expect(found.remoteSnapshot!['body'], 'remote winning');
        expect(found.baseSnapshot!['body'], 'base');
        expect(found.isOpen, isTrue);
        expect(await repo.openCount(profileId), 1);
      });
    },
  );

  test('[TEST-DB-SYNC-CONFLICT-PULL-IDEMPOTENT][V1][TASK-9.3][R-SYNC-004] '
      're-recording the same artifact does not create a duplicate', () async {
    for (int i = 0; i < 3; i += 1) {
      await unitOfWork.transaction<void>((TransactionSession session) async {
        await session.repositories
            .resolve<SyncConflictRepository>()
            .upsertArtifact(
              profileId: profileId,
              id: 'local-pk-$i',
              artifact: _artifact(),
            );
      });
    }

    await unitOfWork.transaction<void>((TransactionSession session) async {
      final SyncConflictRepository repo = session.repositories
          .resolve<SyncConflictRepository>();
      expect(await repo.openCount(profileId), 1);
      final List<ConflictArtifact> open = await repo.listOpen(profileId);
      expect(open, hasLength(1));
      expect(open.single.remoteArtifactId, 'artifact-1');
    });
  });

  test(
    '[TEST-DB-SYNC-CONFLICT-RESOLVE-IDEMPOTENT][V1][TASK-9.3][R-SYNC-004] '
    'resolving is idempotent: only the first resolution changes a row',
    () async {
      await unitOfWork.transaction<void>((TransactionSession session) async {
        await session.repositories
            .resolve<SyncConflictRepository>()
            .upsertArtifact(
              profileId: profileId,
              id: 'local-pk-1',
              artifact: _artifact(),
            );
      });

      late int firstChanged;
      await unitOfWork.transaction<void>((TransactionSession session) async {
        firstChanged = await session.repositories
            .resolve<SyncConflictRepository>()
            .resolve(
              profileId: profileId,
              remoteArtifactId: 'artifact-1',
              resolution: 'kept_remote',
              resolvedAtUtc: 500,
            );
      });
      expect(firstChanged, 1);

      late int secondChanged;
      await unitOfWork.transaction<void>((TransactionSession session) async {
        secondChanged = await session.repositories
            .resolve<SyncConflictRepository>()
            .resolve(
              profileId: profileId,
              remoteArtifactId: 'artifact-1',
              resolution: 'kept_remote',
              resolvedAtUtc: 999,
            );
      });
      expect(secondChanged, 0, reason: 'replay must not change the row again');

      await unitOfWork.transaction<void>((TransactionSession session) async {
        final SyncConflictRepository repo = session.repositories
            .resolve<SyncConflictRepository>();
        expect(await repo.openCount(profileId), 0);
        final ConflictArtifact resolved = (await repo.findByArtifactId(
          profileId,
          'artifact-1',
        ))!;
        expect(resolved.isResolved, isTrue);
        expect(resolved.resolution, 'kept_remote');
        expect(resolved.resolvedAtUtc, 500);
      });
    },
  );
}
