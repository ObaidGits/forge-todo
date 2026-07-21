import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';

import 'learning_test_support.dart';

void main() {
  late LearningHarness harness;

  setUp(() async {
    harness = await LearningHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  group('Learning Resource create/update (R-LEARN-001)', () {
    test(
      'given a book when created then it persists with type and creator',
      () async {
        final String id = await harness.createResource(
          title: 'Deep Work',
          type: LearningResourceType.book,
          creator: 'Cal Newport',
          sourceUri: 'https://example.com/deep-work',
        );

        final LearningResource? resource = await harness.reads.findResource(
          harness.profileId,
          LearningResourceId(id),
        );
        expect(resource, isNotNull);
        expect(resource!.type, LearningResourceType.book);
        expect(resource.creator, 'Cal Newport');
        expect(resource.sourceUri, 'https://example.com/deep-work');
        expect(resource.status, LearningResourceStatus.active);
        expect(resource.progressMode, LearningProgressMode.derived);
      },
    );

    test('given every resource type then all persist (R-LEARN-001)', () async {
      for (final LearningResourceType type in LearningResourceType.values) {
        final String id = await harness.createResource(
          title: 'A ${type.wire}',
          type: type,
          seed: 'res-${type.wire}',
        );
        final LearningResource? resource = await harness.reads.findResource(
          harness.profileId,
          LearningResourceId(id),
        );
        expect(resource!.type, type);
      }
    });

    test(
      'creating a resource writes exactly one committed row and a receipt',
      () async {
        final String id = await harness.createResource();
        expect(
          await harness.scalar(
            'SELECT COUNT(*) FROM courses WHERE id = ?',
            <Object?>[id],
          ),
          1,
        );
        expect(
          await harness.scalar('SELECT COUNT(*) FROM command_receipts'),
          1,
        );
        expect(
          await harness.scalar('SELECT COUNT(*) FROM outbox_mutations'),
          1,
        );
      },
    );

    test(
      'same command id and hash replays the stored receipt (R-GEN-005)',
      () async {
        final CommandId cmd = harness.nextCommandId('dup');
        final CreateResourceInput input = CreateResourceInput(
          lifeAreaId: harness.lifeAreaId.value,
          title: 'Idempotent',
          type: LearningResourceType.course,
        );
        final CommittedCommandResult first = harness.expectSuccess(
          await harness.service.createResource(
            commandId: cmd,
            profileId: harness.profileId,
            input: input,
          ),
        );
        final CommittedCommandResult second = harness.expectSuccess(
          await harness.service.createResource(
            commandId: cmd,
            profileId: harness.profileId,
            input: input,
          ),
        );
        expect(first.replayed, isFalse);
        expect(second.replayed, isTrue);
        expect(await harness.scalar('SELECT COUNT(*) FROM courses'), 1);
      },
    );

    test('update changes title/status and bumps revision', () async {
      final String id = await harness.createResource(title: 'Old');
      harness.expectSuccess(
        await harness.service.updateResource(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: UpdateResourceInput(
            resourceId: id,
            title: 'New',
            status: LearningResourceStatus.completed,
          ),
        ),
      );
      final LearningResource? resource = await harness.reads.findResource(
        harness.profileId,
        LearningResourceId(id),
      );
      expect(resource!.title, 'New');
      expect(resource.status, LearningResourceStatus.completed);
      expect(resource.revision, 2);
    });
  });

  group('Manual progress mode (R-LEARN-004)', () {
    test('switching to manual requires a value', () async {
      final String id = await harness.createResource();
      final Result<CommittedCommandResult> result = await harness.service
          .updateResource(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            input: UpdateResourceInput(
              resourceId: id,
              progressMode: LearningProgressMode.manual,
            ),
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'learning.manual_progress_required',
      );
    });

    test('manual mode stores clamped value and derived clears it', () async {
      final String id = await harness.createResource();
      harness.expectSuccess(
        await harness.service.updateResource(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: UpdateResourceInput(
            resourceId: id,
            progressMode: LearningProgressMode.manual,
            manualProgressPermille: FieldEdit<int>.set(600),
          ),
        ),
      );
      LearningResource? resource = await harness.reads.findResource(
        harness.profileId,
        LearningResourceId(id),
      );
      expect(resource!.progressMode, LearningProgressMode.manual);
      expect(resource.manualProgressPermille, 600);

      // Switching back to derived clears the manual value (DB CHECK).
      harness.expectSuccess(
        await harness.service.updateResource(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: UpdateResourceInput(
            resourceId: id,
            progressMode: LearningProgressMode.derived,
          ),
        ),
      );
      resource = await harness.reads.findResource(
        harness.profileId,
        LearningResourceId(id),
      );
      expect(resource!.progressMode, LearningProgressMode.derived);
      expect(resource.manualProgressPermille, isNull);
    });
  });

  group('Search projection (R-SEARCH-001)', () {
    test(
      'resource title is indexed and findable, delete tombstones it',
      () async {
        final String id = await harness.createResource(
          title: 'Unique Kotlin Guide',
          creator: 'Author X',
        );
        // The learning projector maintained search_documents in-commit.
        expect(
          await harness.scalar(
            "SELECT COUNT(*) FROM search_documents "
            "WHERE entity_type = 'learning_resource' AND entity_id = ?",
            <Object?>[id],
          ),
          1,
        );

        harness.expectSuccess(
          await harness.service.deleteResource(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            resourceId: id,
          ),
        );
        // Soft-delete removes/hides the document transactionally.
        final int visible = await harness.scalar(
          "SELECT COUNT(*) FROM search_documents "
          "WHERE entity_type = 'learning_resource' AND entity_id = ? "
          'AND deleted = 0',
          <Object?>[id],
        );
        expect(visible, 0);
        // The read model no longer returns a soft-deleted resource.
        expect(
          await harness.reads.findResource(
            harness.profileId,
            LearningResourceId(id),
          ),
          isNull,
        );
      },
    );
  });

  group('Ownership (R-GEN-002)', () {
    test('a resource is rejected for a life area of another profile', () async {
      await harness.db.customStatement(
        'INSERT INTO profiles '
        '(id, display_name, locale, timezone_id, week_start, hour_format, '
        'is_active, created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>['profile-2', 'Other', 'en', 'UTC', 1, 'h24', 0, 0, 0],
      );
      await harness.db.customStatement(
        'INSERT INTO life_areas '
        '(id, profile_id, name, normalized_name, rank, is_default, '
        'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>['area-foreign', 'profile-2', 'X', 'x', 'm', 0, 0, 0],
      );
      // The active profile cannot own a resource classified under another
      // profile's life area: the composite FK rejects it and the transaction
      // rolls back, so no row is written.
      await expectLater(
        harness.service.createResource(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: const CreateResourceInput(
            lifeAreaId: 'area-foreign',
            title: 'Cross',
            type: LearningResourceType.other,
          ),
        ),
        throwsA(anything),
      );
      expect(await harness.scalar('SELECT COUNT(*) FROM courses'), 0);
    });
  });
}
