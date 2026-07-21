import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_repository.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'goal_test_support.dart';

/// Real Drift-backed goal/milestone/progress-policy/archive tests
/// (R-GOAL-001, R-GOAL-002, R-GOAL-004, R-GOAL-006, R-GOAL-007, R-GEN-005).
///
/// **Validates: Requirements R-GOAL-001, R-GOAL-002, R-GOAL-004, R-GOAL-006, R-GOAL-007**
void main() {
  late GoalHarness h;

  setUp(() async {
    h = await GoalHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('given goal creation (R-GOAL-001, R-GOAL-002)', () {
    test('then unlimited goals can be created with no gating', () async {
      for (int i = 0; i < 25; i += 1) {
        await h.createGoal(title: 'Goal $i', seed: 'g$i');
      }
      final int count = await h.scalar(
        'SELECT COUNT(*) FROM goals WHERE profile_id = ?',
        <Object?>[h.profileId.value],
      );
      expect(count, 25);
    });

    test('then a created goal carries its core fields and area', () async {
      final String id = await h.createGoal(
        title: 'Ship v1',
        outcomeMd: 'A shippable release',
        targetDate: '2025-01-01',
        manualProgress: 0.25,
      );
      final Goal? goal = await h.reads.findById(h.profileId, GoalId(id));
      expect(goal, isNotNull);
      expect(goal!.title, 'Ship v1');
      expect(goal.outcomeMd, 'A shippable release');
      expect(goal.lifeAreaId, h.lifeAreaId);
      expect(goal.status, GoalStatus.active);
      expect(goal.targetDate, '2025-01-01');
      expect(goal.progressMode, GoalProgressMode.manual);
      expect(goal.manualProgress, 0.25);
    });

    test('then goals get distinct stable ranks in creation order', () async {
      final String a = await h.createGoal(title: 'A', seed: 'a');
      final String b = await h.createGoal(title: 'B', seed: 'b');
      final Goal ga = (await h.reads.findById(h.profileId, GoalId(a)))!;
      final Goal gb = (await h.reads.findById(h.profileId, GoalId(b)))!;
      expect(ga.rank.value.compareTo(gb.rank.value) < 0, isTrue);
    });

    test('then an empty title is rejected as a validation failure', () async {
      final Result<CommittedCommandResult> result = await h.goals.create(
        commandId: h.nextCommandId(),
        profileId: h.profileId,
        input: CreateGoalInput(lifeAreaId: h.lifeAreaId, title: '   '),
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.kind, FailureKind.validation);
    });
  });

  group('given the progress strategy (R-GOAL-004)', () {
    test('then a manual value is clamped into 0..1 on set', () async {
      final String id = await h.createGoal(manualProgress: 0.0);
      await h.goals.setManualProgress(
        commandId: h.nextCommandId(),
        profileId: h.profileId,
        goalId: GoalId(id),
        value: 1.7,
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(id)))!;
      expect(goal.manualProgress, 1.0);
      expect(goal.manualProgressSurface.value, 1.0);
    });

    test('then switching to derived clears the manual value', () async {
      final String id = await h.createGoal(manualProgress: 0.5);
      await h.goals.setProgressPolicy(
        commandId: h.nextCommandId(),
        profileId: h.profileId,
        goalId: GoalId(id),
        input: const SetProgressPolicyInput(mode: GoalProgressMode.derived),
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(id)))!;
      expect(goal.progressMode, GoalProgressMode.derived);
      expect(goal.manualProgress, isNull);
    });

    test('then a derived goal has no computable progress without topics '
        'and exposes the transparent formula surface', () async {
      final String id = await h.createGoal(
        progressMode: GoalProgressMode.derived,
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(id)))!;
      // With no roadmap topics (task 6.2) the derived surface is "not started".
      final GoalProgress derived = GoalProgressPolicy.derived(
        const <GoalProgressLeaf>[],
      );
      expect(goal.progressMode, GoalProgressMode.derived);
      expect(derived.value, isNull);
      expect(derived.formula, GoalProgressPolicy.derivedFormula);
      expect(derived.eligibleCount, 0);
      expect(derived.totalWeight, 0);
    });

    test('then setting a manual value on a derived goal is rejected', () async {
      final String id = await h.createGoal(
        progressMode: GoalProgressMode.derived,
      );
      final Result<CommittedCommandResult> result = await h.goals
          .setManualProgress(
            commandId: h.nextCommandId(),
            profileId: h.profileId,
            goalId: GoalId(id),
            value: 0.5,
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.code, 'goal.not_manual_mode');
    });

    test(
      'then the manual/derived column CHECK holds at the database',
      () async {
        final String id = await h.createGoal(
          progressMode: GoalProgressMode.derived,
        );
        // A derived goal must have NULL manual_progress.
        final int violating = await h.scalar(
          'SELECT COUNT(*) FROM goals WHERE id = ? '
          "AND progress_mode = 'derived' AND manual_progress IS NOT NULL",
          <Object?>[id],
        );
        expect(violating, 0);
      },
    );
  });

  group('given lifecycle status (R-GOAL-002)', () {
    test('then status transitions persist and are idempotent', () async {
      final String id = await h.createGoal();
      final Result<CommittedCommandResult> first = await h.goals.setStatus(
        commandId: h.nextCommandId('s1'),
        profileId: h.profileId,
        goalId: GoalId(id),
        status: GoalStatus.achieved,
      );
      expect(
        (first as Success<CommittedCommandResult>).value.resultCode,
        'status_changed',
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(id)))!;
      expect(goal.status, GoalStatus.achieved);

      // Re-issuing the identical command replays the stored receipt.
      final Result<CommittedCommandResult> replay = await h.goals.setStatus(
        commandId: h.nextCommandId('s1'),
        profileId: h.profileId,
        goalId: GoalId(id),
        status: GoalStatus.achieved,
      );
      expect(
        (replay as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
    });
  });

  group('given archival (R-GOAL-007)', () {
    test(
      'then archiving preserves the goal, its milestones and its tags',
      () async {
        final String tagId = await _insertTag(h);
        final String goalId = await h.createGoal(tagIds: <String>[tagId]);
        final String m1 = await h.addMilestone(goalId, seed: 'm1');
        await h.addMilestone(goalId, title: 'Second', seed: 'm2');

        await h.goals.setArchived(
          commandId: h.nextCommandId(),
          profileId: h.profileId,
          goalId: GoalId(goalId),
          archived: true,
        );

        final Goal goal = (await h.reads.findById(
          h.profileId,
          GoalId(goalId),
        ))!;
        expect(goal.isArchived, isTrue);
        expect(goal.isDeleted, isFalse);

        // Milestones and tags survive archival unchanged (history + links).
        final List<Milestone> milestones = await h.reads.milestonesOf(
          h.profileId,
          GoalId(goalId),
        );
        expect(milestones.length, 2);
        final List<String> tags = await h.reads.tagIdsFor(
          h.profileId,
          GoalId(goalId),
        );
        expect(tags, <String>[tagId]);

        // The milestone completion history remains addressable.
        final Milestone? found = await h.reads.findMilestone(
          h.profileId,
          MilestoneId(m1),
        );
        expect(found, isNotNull);
      },
    );

    test(
      'then archived goals leave the active view and enter the archived view',
      () async {
        final String goalId = await h.createGoal();
        await h.goals.setArchived(
          commandId: h.nextCommandId(),
          profileId: h.profileId,
          goalId: GoalId(goalId),
          archived: true,
        );
        final List<Goal> active = await h.reads.view(
          h.profileId,
          GoalViewKind.active,
        );
        final List<Goal> archived = await h.reads.view(
          h.profileId,
          GoalViewKind.archived,
        );
        expect(active.where((Goal g) => g.id.value == goalId), isEmpty);
        expect(archived.map((Goal g) => g.id.value), contains(goalId));
      },
    );

    test('then unarchiving clears the archive instant', () async {
      final String goalId = await h.createGoal();
      await h.goals.setArchived(
        commandId: h.nextCommandId('a'),
        profileId: h.profileId,
        goalId: GoalId(goalId),
        archived: true,
      );
      await h.goals.setArchived(
        commandId: h.nextCommandId('b'),
        profileId: h.profileId,
        goalId: GoalId(goalId),
        archived: false,
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(goalId)))!;
      expect(goal.isArchived, isFalse);
    });
  });

  group('given milestones and completion history (R-GOAL-002, R-GOAL-006)', () {
    test(
      'then a milestone belongs to its goal and inherits nothing extra',
      () async {
        final String goalId = await h.createGoal();
        final String milestoneId = await h.addMilestone(
          goalId,
          title: 'Alpha',
          targetDate: '2025-03-01',
        );
        final Milestone m = (await h.reads.findMilestone(
          h.profileId,
          MilestoneId(milestoneId),
        ))!;
        expect(m.goalId.value, goalId);
        expect(m.title, 'Alpha');
        expect(m.targetDate, '2025-03-01');
        expect(m.isCompleted, isFalse);
      },
    );

    test(
      'then completing a milestone records the instant and appends history',
      () async {
        final String goalId = await h.createGoal();
        final String milestoneId = await h.addMilestone(goalId);
        await h.goals.completeMilestone(
          commandId: h.nextCommandId('c'),
          profileId: h.profileId,
          milestoneId: MilestoneId(milestoneId),
        );
        final Milestone m = (await h.reads.findMilestone(
          h.profileId,
          MilestoneId(milestoneId),
        ))!;
        expect(m.isCompleted, isTrue);

        // Toggling completion off and on again preserves append-only history:
        // the milestone row shows the current state, activity keeps every event.
        await h.goals.uncompleteMilestone(
          commandId: h.nextCommandId('u'),
          profileId: h.profileId,
          milestoneId: MilestoneId(milestoneId),
        );
        await h.goals.completeMilestone(
          commandId: h.nextCommandId('c2'),
          profileId: h.profileId,
          milestoneId: MilestoneId(milestoneId),
        );
        final int completionEvents = await h.scalar(
          'SELECT COUNT(*) FROM activity_events '
          "WHERE profile_id = ? AND entity_id = ? AND event_type = 'milestone_completed'",
          <Object?>[h.profileId.value, milestoneId],
        );
        expect(completionEvents, 2);
        final int uncompletionEvents = await h.scalar(
          'SELECT COUNT(*) FROM activity_events '
          "WHERE profile_id = ? AND entity_id = ? AND event_type = 'milestone_uncompleted'",
          <Object?>[h.profileId.value, milestoneId],
        );
        expect(uncompletionEvents, 1);

        final Milestone finalState = (await h.reads.findMilestone(
          h.profileId,
          MilestoneId(milestoneId),
        ))!;
        expect(finalState.isCompleted, isTrue);
      },
    );

    test(
      'then re-completing an already-complete milestone is a no-op',
      () async {
        final String goalId = await h.createGoal();
        final String milestoneId = await h.addMilestone(goalId);
        await h.goals.completeMilestone(
          commandId: h.nextCommandId('c'),
          profileId: h.profileId,
          milestoneId: MilestoneId(milestoneId),
        );
        final Result<CommittedCommandResult> again = await h.goals
            .completeMilestone(
              commandId: h.nextCommandId('c-again'),
              profileId: h.profileId,
              milestoneId: MilestoneId(milestoneId),
            );
        expect(
          (again as Success<CommittedCommandResult>).value.resultCode,
          'noop',
        );
      },
    );

    test(
      'then milestone reordering produces a rank between neighbours',
      () async {
        final String goalId = await h.createGoal();
        final String a = await h.addMilestone(goalId, title: 'A', seed: 'ma');
        final String b = await h.addMilestone(goalId, title: 'B', seed: 'mb');
        final String c = await h.addMilestone(goalId, title: 'C', seed: 'mc');
        final Milestone ma = (await h.reads.findMilestone(
          h.profileId,
          MilestoneId(a),
        ))!;
        final Milestone mb = (await h.reads.findMilestone(
          h.profileId,
          MilestoneId(b),
        ))!;
        // Move C between A and B.
        await h.goals.moveMilestone(
          commandId: h.nextCommandId('mv'),
          profileId: h.profileId,
          milestoneId: MilestoneId(c),
          input: MoveInput(beforeRank: ma.rank.value, afterRank: mb.rank.value),
        );
        final List<Milestone> ordered = await h.reads.milestonesOf(
          h.profileId,
          GoalId(goalId),
        );
        expect(ordered.map((Milestone m) => m.id.value).toList(), <String>[
          a,
          c,
          b,
        ]);
      },
    );
  });

  group('given the canonical note reference (R-GOAL-002)', () {
    test('then a goal can reference an existing note', () async {
      final String noteId = await h.createNote(seed: 'note');
      final String goalId = await h.createGoal(
        noteId: NoteId(noteId),
        seed: 'goal',
      );
      final Goal goal = (await h.reads.findById(h.profileId, GoalId(goalId)))!;
      expect(goal.noteId?.value, noteId);
    });

    test('then referencing a non-existent note is rejected', () async {
      final Result<CommittedCommandResult> result = await h.goals.create(
        commandId: h.nextCommandId(),
        profileId: h.profileId,
        input: CreateGoalInput(
          lifeAreaId: h.lifeAreaId,
          title: 'Orphan ref',
          noteId: NoteId('does-not-exist'),
        ),
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(result.failureOrNull!.code, 'goal.note_not_found');
    });
  });

  group('given the unified search index (R-SEARCH-001)', () {
    test(
      'then a created goal is discoverable by title and outcome text',
      () async {
        await h.createGoal(
          title: 'Master calligraphy',
          outcomeMd: 'Write beautiful invitations',
          seed: 'cal',
        );
        final SearchResults byTitle = await h.search.search(
          h.profileId,
          'calligraphy',
          types: <String>{'goal'},
        );
        expect(byTitle.totalHits, greaterThan(0));

        final SearchResults byBody = await h.search.search(
          h.profileId,
          'invitations',
          types: <String>{'goal'},
        );
        expect(byBody.totalHits, greaterThan(0));
      },
    );

    test(
      'then editing the title updates the search projection in-commit',
      () async {
        final String goalId = await h.createGoal(
          title: 'Original title',
          seed: 'orig',
        );
        await h.goals.update(
          commandId: h.nextCommandId('rename'),
          profileId: h.profileId,
          goalId: GoalId(goalId),
          input: const UpdateGoalInput(title: 'Renamed objective'),
        );
        final SearchResults results = await h.search.search(
          h.profileId,
          'Renamed',
          types: <String>{'goal'},
        );
        expect(results.totalHits, greaterThan(0));
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
    test(
      'then creating a goal writes the receipt, activity and outbox group',
      () async {
        final String goalId = await h.createGoal(seed: 'atomic');
        final int receipts = await h.scalar(
          'SELECT COUNT(*) FROM command_receipts WHERE profile_id = ?',
          <Object?>[h.profileId.value],
        );
        expect(receipts, greaterThan(0));
        final int activity = await h.scalar(
          "SELECT COUNT(*) FROM activity_events WHERE profile_id = ? "
          "AND entity_id = ? AND event_type = 'created'",
          <Object?>[h.profileId.value, goalId],
        );
        expect(activity, 1);
        final int outbox = await h.scalar(
          'SELECT COUNT(*) FROM outbox_mutations WHERE profile_id = ? '
          "AND entity_type = 'goal' AND entity_id = ?",
          <Object?>[h.profileId.value, goalId],
        );
        expect(outbox, 1);
      },
    );
  });
}

Future<String> _insertTag(GoalHarness h) async {
  await h.db.customStatement(
    'INSERT INTO tags '
    '(id, profile_id, normalized_name, display_name, created_at_utc, '
    'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
    <Object?>['tag-goal', h.profileId.value, 'growth', 'Growth', 0, 0],
  );
  return 'tag-goal';
}
