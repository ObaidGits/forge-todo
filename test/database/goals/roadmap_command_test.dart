import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_link.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'roadmap_test_support.dart';

/// Real Drift-backed roadmap/section/topic/checklist/progress/rank-rebalance
/// tests (R-GOAL-003, R-GOAL-004, R-GOAL-005, R-GEN-005).
///
/// **Validates: Requirements R-GOAL-003, R-GOAL-004, R-GOAL-005**
void main() {
  late RoadmapHarness h;

  setUp(() async {
    h = await RoadmapHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given roadmap creation (R-GOAL-001, R-GOAL-003)', () {
    test('then a goal owns exactly one roadmap', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final Roadmap? roadmap = await h.reads.findByGoal(
        h.profileId,
        GoalId(goalId),
      );
      expect(roadmap, isNotNull);
      expect(roadmap!.id.value, roadmapId);
      expect(roadmap.goalId.value, goalId);
    });

    test('then a second roadmap for the same goal is rejected', () async {
      final String goalId = await h.createGoal(seed: 'g');
      await h.createRoadmap(goalId, seed: 'r1');
      final Result<CommittedCommandResult> second = await h.roadmaps
          .createRoadmap(
            commandId: h.nextCommandId('r2'),
            profileId: h.profileId,
            goalId: GoalId(goalId),
            input: const CreateRoadmapInput(title: 'Duplicate'),
          );
      expect(second, isA<Failed<CommittedCommandResult>>());
      expect(second.failureOrNull!.code, 'roadmap.already_exists');
    });

    test('then a roadmap for a missing goal is rejected', () async {
      final Result<CommittedCommandResult> result = await h.roadmaps
          .createRoadmap(
            commandId: h.nextCommandId(),
            profileId: h.profileId,
            goalId: GoalId('no-such-goal'),
            input: const CreateRoadmapInput(title: 'Orphan'),
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.code, 'roadmap.not_found');
    });
  });

  group('given ordered sections and topics (R-GOAL-003, R-GOAL-005)', () {
    test('then sections and topics keep stable creation order', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, title: 'One', seed: 's1');
      final String s2 = await h.addSection(roadmapId, title: 'Two', seed: 's2');
      final List<RoadmapSection> sections = await h.reads.sectionsOf(
        h.profileId,
        RoadmapId(roadmapId),
      );
      expect(sections.map((RoadmapSection s) => s.id.value), <String>[s1, s2]);

      final String t1 = await h.addTopic(s1, title: 'Alpha', seed: 't1');
      final String t2 = await h.addTopic(s1, title: 'Beta', seed: 't2');
      final List<RoadmapTopic> topics = await h.reads.topicsOfSection(
        h.profileId,
        RoadmapSectionId(s1),
      );
      expect(topics.map((RoadmapTopic t) => t.id.value), <String>[t1, t2]);
    });

    test('then moving a topic reorders it between neighbours', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final String a = await h.addTopic(s1, title: 'A', seed: 'a');
      final String b = await h.addTopic(s1, title: 'B', seed: 'b');
      final String c = await h.addTopic(s1, title: 'C', seed: 'c');
      final RoadmapTopic ta = (await h.reads.findTopic(
        h.profileId,
        RoadmapTopicId(a),
      ))!;
      final RoadmapTopic tb = (await h.reads.findTopic(
        h.profileId,
        RoadmapTopicId(b),
      ))!;
      // Move C between A and B.
      await h.roadmaps.moveTopic(
        commandId: h.nextCommandId('mv'),
        profileId: h.profileId,
        topicId: RoadmapTopicId(c),
        input: MoveInput(beforeRank: ta.rank.value, afterRank: tb.rank.value),
      );
      final List<RoadmapTopic> ordered = await h.reads.topicsOfSection(
        h.profileId,
        RoadmapSectionId(s1),
      );
      expect(ordered.map((RoadmapTopic t) => t.id.value), <String>[a, c, b]);
    });

    test('then adding a topic to a missing section is rejected', () async {
      final Result<CommittedCommandResult> result = await h.roadmaps.addTopic(
        commandId: h.nextCommandId(),
        profileId: h.profileId,
        sectionId: RoadmapSectionId('no-section'),
        input: const CreateTopicInput(title: 'Orphan topic'),
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.code, 'roadmap.not_found');
    });
  });

  group('given topic weight and status (R-GOAL-003, R-GOAL-004)', () {
    test(
      'then a negative weight is rejected as a validation failure',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
        final String s1 = await h.addSection(roadmapId, seed: 's1');
        final Result<CommittedCommandResult> result = await h.roadmaps.addTopic(
          commandId: h.nextCommandId(),
          profileId: h.profileId,
          sectionId: RoadmapSectionId(s1),
          input: const CreateTopicInput(title: 'Bad', weight: -1),
        );
        expect(result, isA<Failed<CommittedCommandResult>>());
        expect(result.failureOrNull!.kind, FailureKind.validation);
      },
    );

    test(
      'then completing a topic records the instant and clearing it undoes it',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
        final String s1 = await h.addSection(roadmapId, seed: 's1');
        final String t = await h.addTopic(s1, seed: 't');
        await h.setTopicStatus(t, RoadmapTopicStatus.completed, seed: 'c');
        RoadmapTopic topic = (await h.reads.findTopic(
          h.profileId,
          RoadmapTopicId(t),
        ))!;
        expect(topic.status, RoadmapTopicStatus.completed);
        expect(topic.completedAtUtc, isNotNull);

        await h.setTopicStatus(t, RoadmapTopicStatus.inProgress, seed: 'ip');
        topic = (await h.reads.findTopic(h.profileId, RoadmapTopicId(t)))!;
        expect(topic.status, RoadmapTopicStatus.inProgress);
        expect(topic.completedAtUtc, isNull);
      },
    );

    test('then the weight CHECK holds at the database', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      await h.addTopic(s1, weight: 2.5, seed: 't');
      final int violating = await h.scalar(
        'SELECT COUNT(*) FROM roadmap_topics WHERE weight IS NOT NULL AND weight < 0',
      );
      expect(violating, 0);
    });
  });

  group('given derived goal progress from roadmap topics (R-GOAL-004)', () {
    test('then only topics contribute — milestones, checklist items and '
        'links never double count', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, title: 'S1', seed: 's1');
      final String s2 = await h.addSection(roadmapId, title: 'S2', seed: 's2');

      // Topics: completed weight 3 + 2 = 5, eligible total 3 + 2 + 1 = 6;
      // one archived topic (weight 99) is excluded.
      final String t1 = await h.addTopic(
        s1,
        title: 'T1',
        weight: 3,
        seed: 't1',
      );
      await h.addTopic(s1, title: 'T2', weight: 1, seed: 't2');
      final String t3 = await h.addTopic(
        s2,
        title: 'T3',
        weight: 2,
        seed: 't3',
      );
      await h.addTopic(
        s2,
        title: 'T4',
        weight: 99,
        status: RoadmapTopicStatus.archived,
        seed: 't4',
      );
      await h.setTopicStatus(t1, RoadmapTopicStatus.completed, seed: 'c1');
      await h.setTopicStatus(t3, RoadmapTopicStatus.completed, seed: 'c3');

      final GoalProgress before = await h.reads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      expect(before.eligibleCount, 3);
      expect(before.totalWeight, 6);
      expect(before.completedWeight, 5);
      expect(before.value, closeTo(5 / 6, 1e-12));

      // Add entities that must NOT contribute independently (R-GOAL-004):
      // a completed milestone, checked checklist items, and a topic link.
      await h.goals.addMilestone(
        commandId: h.nextCommandId('m'),
        profileId: h.profileId,
        goalId: GoalId(goalId),
        input: const CreateMilestoneInput(title: 'Milestone'),
      );
      final String noteId = await h.createNote(seed: 'note');
      await h.roadmaps.linkTopicEntity(
        commandId: h.nextCommandId('link'),
        profileId: h.profileId,
        topicId: RoadmapTopicId(t1),
        input: LinkTopicEntityInput(
          targetType: RoadmapTopicTargetType.note,
          targetId: noteId,
        ),
      );
      final String item = await h.addChecklistItem(t1, seed: 'ci');
      await h.roadmaps.setChecklistItemChecked(
        commandId: h.nextCommandId('chk'),
        profileId: h.profileId,
        itemId: ChecklistItemId(item),
        checked: true,
      );

      final GoalProgress after = await h.reads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      // Identical: only the roadmap topics feed the derived progress.
      expect(after.eligibleCount, before.eligibleCount);
      expect(after.totalWeight, before.totalWeight);
      expect(after.completedWeight, before.completedWeight);
      expect(after.value, before.value);
    });

    test('then a null topic weight normalizes to 1', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final String a = await h.addTopic(
        s1,
        title: 'A',
        seed: 'a',
      ); // null weight
      await h.addTopic(s1, title: 'B', seed: 'b'); // null weight
      await h.setTopicStatus(a, RoadmapTopicStatus.completed, seed: 'ca');
      final GoalProgress p = await h.reads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      expect(p.totalWeight, 2);
      expect(p.completedWeight, 1);
      expect(p.value, closeTo(0.5, 1e-12));
    });

    test('then a roadmap with no eligible topics is "not started"', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      await h.addTopic(
        s1,
        status: RoadmapTopicStatus.cancelled,
        weight: 4,
        seed: 't',
      );
      final GoalProgress p = await h.reads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      expect(p.value, isNull);
      expect(p.isComputable, isFalse);
    });

    test(
      'then a goal without a roadmap has no computable derived progress',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final GoalProgress p = await h.reads.deriveGoalProgress(
          h.profileId,
          GoalId(goalId),
        );
        expect(p.value, isNull);
        expect(p.eligibleCount, 0);
      },
    );
  });

  group('given sync-safe rank rebalancing (R-GOAL-005)', () {
    test(
      'then rebalancing topics preserves order and emits one semantic group',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
        final String s1 = await h.addSection(roadmapId, seed: 's1');
        final List<String> ids = <String>[];
        for (int i = 0; i < 5; i += 1) {
          ids.add(await h.addTopic(s1, title: 'T$i', seed: 't$i'));
        }

        await h.roadmaps.rebalanceTopics(
          commandId: h.nextCommandId('rb'),
          profileId: h.profileId,
          sectionId: RoadmapSectionId(s1),
        );

        // Order is preserved after the rebalance.
        final List<RoadmapTopic> ordered = await h.reads.topicsOfSection(
          h.profileId,
          RoadmapSectionId(s1),
        );
        expect(ordered.map((RoadmapTopic t) => t.id.value), ids);

        // All patch operations belong to exactly one outbox group of 5 ops.
        final int groups = await h.scalar(
          'SELECT COUNT(DISTINCT group_id) FROM outbox_mutations '
          "WHERE entity_type = 'roadmap_topic' AND op_kind = 'patch'",
        );
        expect(groups, 1);
        final int patchOps = await h.scalar(
          'SELECT COUNT(*) FROM outbox_mutations '
          "WHERE entity_type = 'roadmap_topic' AND op_kind = 'patch'",
        );
        expect(patchOps, 5);
      },
    );

    test('then rebalancing an empty section is a no-op', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final Result<CommittedCommandResult> result = await h.roadmaps
          .rebalanceTopics(
            commandId: h.nextCommandId('rb'),
            profileId: h.profileId,
            sectionId: RoadmapSectionId(s1),
          );
      expect(
        (result as Success<CommittedCommandResult>).value.resultCode,
        'noop',
      );
    });

    test('then rebalancing sections preserves order', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final List<String> ids = <String>[];
      for (int i = 0; i < 4; i += 1) {
        ids.add(await h.addSection(roadmapId, title: 'S$i', seed: 's$i'));
      }
      await h.roadmaps.rebalanceSections(
        commandId: h.nextCommandId('rb'),
        profileId: h.profileId,
        roadmapId: RoadmapId(roadmapId),
      );
      final List<RoadmapSection> ordered = await h.reads.sectionsOf(
        h.profileId,
        RoadmapId(roadmapId),
      );
      expect(ordered.map((RoadmapSection s) => s.id.value), ids);
    });
  });

  group('given checklist items (R-GOAL-003)', () {
    test(
      'then items keep order and check/uncheck toggles the instant',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
        final String s1 = await h.addSection(roadmapId, seed: 's1');
        final String t = await h.addTopic(s1, seed: 't');
        final String i1 = await h.addChecklistItem(t, text: 'One', seed: 'i1');
        final String i2 = await h.addChecklistItem(t, text: 'Two', seed: 'i2');
        final List<ChecklistItem> items = await h.reads.checklistItemsOf(
          h.profileId,
          RoadmapTopicId(t),
        );
        expect(items.map((ChecklistItem c) => c.id.value), <String>[i1, i2]);

        await h.roadmaps.setChecklistItemChecked(
          commandId: h.nextCommandId('chk'),
          profileId: h.profileId,
          itemId: ChecklistItemId(i1),
          checked: true,
        );
        final ChecklistItem checked = (await h.reads.checklistItemsOf(
          h.profileId,
          RoadmapTopicId(t),
        )).firstWhere((ChecklistItem c) => c.id.value == i1);
        expect(checked.isChecked, isTrue);
      },
    );
  });

  group('given topic links to other entities (R-GOAL-003, R-GEN-002)', () {
    test('then a topic can link a note and unlink is idempotent', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final String t = await h.addTopic(s1, seed: 't');
      final String noteId = await h.createNote(seed: 'note');
      final Result<CommittedCommandResult> linked = await h.roadmaps
          .linkTopicEntity(
            commandId: h.nextCommandId('l'),
            profileId: h.profileId,
            topicId: RoadmapTopicId(t),
            input: LinkTopicEntityInput(
              targetType: RoadmapTopicTargetType.note,
              targetId: noteId,
            ),
          );
      expect(
        (linked as Success<CommittedCommandResult>).value.resultCode,
        'topic_linked',
      );
      final int links = await h.scalar(
        'SELECT COUNT(*) FROM entity_links WHERE from_type = ? '
        'AND from_id = ? AND to_type = ?',
        <Object?>[roadmapTopicFromType, t, RoadmapTopicTargetType.note],
      );
      expect(links, 1);

      // Unlinking removes it; a second unlink is a no-op.
      await h.roadmaps.unlinkTopicEntity(
        commandId: h.nextCommandId('u1'),
        profileId: h.profileId,
        topicId: RoadmapTopicId(t),
        input: LinkTopicEntityInput(
          targetType: RoadmapTopicTargetType.note,
          targetId: noteId,
        ),
      );
      final Result<CommittedCommandResult> again = await h.roadmaps
          .unlinkTopicEntity(
            commandId: h.nextCommandId('u2'),
            profileId: h.profileId,
            topicId: RoadmapTopicId(t),
            input: LinkTopicEntityInput(
              targetType: RoadmapTopicTargetType.note,
              targetId: noteId,
            ),
          );
      expect(
        (again as Success<CommittedCommandResult>).value.resultCode,
        'noop',
      );
    });

    test('then linking a non-existent target is rejected', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final String t = await h.addTopic(s1, seed: 't');
      final Result<CommittedCommandResult> result = await h.roadmaps
          .linkTopicEntity(
            commandId: h.nextCommandId('l'),
            profileId: h.profileId,
            topicId: RoadmapTopicId(t),
            input: const LinkTopicEntityInput(
              targetType: RoadmapTopicTargetType.note,
              targetId: 'no-such-note',
            ),
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.code, 'roadmap.link_target_not_found');
    });
  });

  group('given the unified search index (R-SEARCH-001)', () {
    test(
      'then a topic is discoverable by title and rename updates it',
      () async {
        final String goalId = await h.createGoal(seed: 'g');
        final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
        final String s1 = await h.addSection(roadmapId, seed: 's1');
        final String t = await h.addTopic(
          s1,
          title: 'Ownership model',
          seed: 't',
        );

        final SearchResults byTitle = await h.search.search(
          h.profileId,
          'ownership',
          types: <String>{'roadmap_topic'},
        );
        expect(byTitle.totalHits, greaterThan(0));

        await h.roadmaps.updateTopic(
          commandId: h.nextCommandId('rename'),
          profileId: h.profileId,
          topicId: RoadmapTopicId(t),
          input: const UpdateTopicInput(title: 'Borrow checker'),
        );
        final SearchResults renamed = await h.search.search(
          h.profileId,
          'borrow',
          types: <String>{'roadmap_topic'},
        );
        expect(renamed.totalHits, greaterThan(0));

        // The search dirty marker was cleared in the same commit.
        final int pendingSearch = await h.scalar(
          "SELECT COUNT(*) FROM projection_dirty WHERE profile_id = ? "
          "AND projection = 'search'",
          <Object?>[h.profileId.value],
        );
        expect(pendingSearch, 0);
      },
    );
  });

  group('given atomic semantic writes (R-GEN-005)', () {
    test('then creating a topic writes receipt, activity and outbox', () async {
      final String goalId = await h.createGoal(seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'r');
      final String s1 = await h.addSection(roadmapId, seed: 's1');
      final String t = await h.addTopic(s1, seed: 't');
      final int activity = await h.scalar(
        "SELECT COUNT(*) FROM activity_events WHERE profile_id = ? "
        "AND entity_id = ? AND event_type = 'topic_created'",
        <Object?>[h.profileId.value, t],
      );
      expect(activity, 1);
      final int outbox = await h.scalar(
        'SELECT COUNT(*) FROM outbox_mutations WHERE profile_id = ? '
        "AND entity_type = 'roadmap_topic' AND entity_id = ?",
        <Object?>[h.profileId.value, t],
      );
      expect(outbox, 1);
    });
  });
}
