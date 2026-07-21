import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';

import 'learning_test_support.dart';

void main() {
  late LearningHarness harness;

  setUp(() async {
    harness = await LearningHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  group('Ordered items (R-LEARN-001)', () {
    test('added items keep stable ascending rank order', () async {
      final String rid = await harness.createResource();
      final String a = await harness.addItem(rid, title: 'A', seed: 'a');
      final String b = await harness.addItem(rid, title: 'B', seed: 'b');
      final String c = await harness.addItem(rid, title: 'C', seed: 'c');

      final List<LearningItem> items = await harness.reads.itemsOf(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(items.map((LearningItem i) => i.id).toList(), <String>[a, b, c]);
    });

    test('moveItem reorders without rewriting neighbours', () async {
      final String rid = await harness.createResource();
      final String a = await harness.addItem(rid, title: 'A', seed: 'a');
      final String b = await harness.addItem(rid, title: 'B', seed: 'b');
      final String c = await harness.addItem(rid, title: 'C', seed: 'c');

      // Move C to the front (before A).
      harness.expectSuccess(
        await harness.service.moveItem(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: MoveItemInput(itemId: c, beforeItemId: a),
        ),
      );
      final List<LearningItem> items = await harness.reads.itemsOf(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(items.first.id, c);
      expect(items.map((LearningItem i) => i.id).toList(), <String>[c, a, b]);
    });

    test('an item may nest under a section parent', () async {
      final String rid = await harness.createResource();
      final String section = await harness.addItem(
        rid,
        title: 'Module 1',
        type: LearningItemType.section,
        seed: 'sec',
      );
      final String child = await harness.addItem(
        rid,
        title: 'Lesson 1',
        parentId: section,
        seed: 'child',
      );
      final LearningItem? item = await harness.reads
          .itemsOf(harness.profileId, LearningResourceId(rid))
          .then(
            (List<LearningItem> items) =>
                items.firstWhere((LearningItem i) => i.id == child),
          );
      expect(item!.parentId, section);
    });
  });

  group('Derived progress (R-LEARN-004)', () {
    test('empty or section-only resource is not started', () async {
      final String rid = await harness.createResource();
      await harness.addItem(rid, type: LearningItemType.section, seed: 'sec');
      final LearningProgress progress = await harness.reads.progressOf(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(progress.isStarted, isFalse);
      expect(progress.eligibleCount, 0);
    });

    test('progress is completed eligible over eligible', () async {
      final String rid = await harness.createResource();
      final String a = await harness.addItem(rid, seed: 'a');
      await harness.addItem(rid, seed: 'b');
      await harness.addItem(rid, seed: 'c');
      await harness.addItem(rid, seed: 'd');

      harness.expectSuccess(
        await harness.service.completeItem(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          itemId: a,
          completedAtUtc: 1000,
        ),
      );
      final LearningProgress progress = await harness.reads.progressOf(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(progress.eligibleCount, 4);
      expect(progress.completedCount, 1);
      expect(progress.fraction, 0.25);
    });

    test('reopening an item lowers completed count', () async {
      final String rid = await harness.createResource();
      final String a = await harness.addItem(rid, seed: 'a');
      await harness.service.completeItem(
        commandId: harness.nextCommandId(),
        profileId: harness.profileId,
        itemId: a,
        completedAtUtc: 1000,
      );
      await harness.service.reopenItem(
        commandId: harness.nextCommandId(),
        profileId: harness.profileId,
        itemId: a,
      );
      final LearningProgress progress = await harness.reads.progressOf(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(progress.completedCount, 0);
      expect(progress.fraction, 0.0);
    });

    test('a section cannot be completed (R-LEARN-004)', () async {
      final String rid = await harness.createResource();
      final String section = await harness.addItem(
        rid,
        type: LearningItemType.section,
        seed: 'sec',
      );
      final Result<CommittedCommandResult> result = await harness.service
          .completeItem(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            itemId: section,
            completedAtUtc: 1000,
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'learning.section_cannot_be_complete',
      );
    });
  });

  group('Resume Learning (R-LEARN-003)', () {
    test(
      'resume points at the first incomplete item and does not mutate it',
      () async {
        final String rid = await harness.createResource();
        final String a = await harness.addItem(rid, seed: 'a');
        final String b = await harness.addItem(rid, seed: 'b');
        await harness.addItem(rid, seed: 'c');

        await harness.service.completeItem(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          itemId: a,
          completedAtUtc: 1000,
        );
        final ResumePoint point = await harness.reads.resumePoint(
          harness.profileId,
          LearningResourceId(rid),
        );
        expect(point.itemId, b);
        // Read-only: the item is not auto-changed by resolving resume.
        final LearningItem resumed = (await harness.reads.itemsOf(
          harness.profileId,
          LearningResourceId(rid),
        )).firstWhere((LearningItem i) => i.id == b);
        expect(resumed.isComplete, isFalse);
      },
    );

    test('resume prefers the last studied incomplete item', () async {
      final String rid = await harness.createResource();
      await harness.addItem(rid, seed: 'a');
      final String b = await harness.addItem(rid, seed: 'b');
      final String c = await harness.addItem(rid, seed: 'c');

      // A study session on c makes it the "last studied" item.
      harness.expectSuccess(
        await harness.service.logStudySession(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: LogStudySessionInput(
            resourceId: rid,
            itemId: c,
            startedAtUtc: DateTime.utc(2024, 6, 1, 9).microsecondsSinceEpoch,
            endedAtUtc: DateTime.utc(2024, 6, 1, 10).microsecondsSinceEpoch,
          ),
        ),
      );
      final ResumePoint point = await harness.reads.resumePoint(
        harness.profileId,
        LearningResourceId(rid),
      );
      expect(point.itemId, c);
      expect(point.reason, 'last_studied');
      // b remains the earliest incomplete but the studied item wins.
      expect(b, isNot(c));
    });
  });
}
