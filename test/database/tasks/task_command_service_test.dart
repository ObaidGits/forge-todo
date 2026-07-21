import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_repository.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

import 'task_test_support.dart';

/// Real Drift-backed task command / repository tests.
///
/// **Validates: Requirements R-TASK-001, R-TASK-002, R-TASK-003, R-TASK-004,
/// R-TASK-008, R-TASK-009, R-TASK-010, R-GEN-005**
void main() {
  late TaskHarness h;

  setUp(() async {
    h = await TaskHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  String idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  Future<String> createTask({
    String seed = '1',
    String title = 'Write the spec',
    TaskDue due = TaskDue.none,
    TaskPriority priority = TaskPriority.none,
    String? scheduledDate,
    TaskId? parent,
    List<String> tagIds = const <String>[],
  }) async {
    final Result<CommittedCommandResult> result = await h.service.create(
      commandId: h.nextCommandId(seed),
      profileId: h.profileId,
      input: CreateTaskInput(
        lifeAreaId: h.lifeAreaId,
        title: title,
        due: due,
        priority: priority,
        scheduledDate: scheduledDate,
        parentTaskId: parent,
        tagIds: tagIds,
      ),
    );
    expect(result, isA<Success<CommittedCommandResult>>());
    return idOf(result);
  }

  group('create (R-TASK-001, R-GEN-005)', () {
    test(
      'commits the task and its cross-cutting write set atomically',
      () async {
        final String id = await createTask();

        expect(await h.scalar('SELECT COUNT(*) FROM tasks'), 1);
        expect(
          await h.scalar(
            "SELECT COUNT(*) FROM tasks WHERE id = ? AND status = 'open'",
            <Object?>[id],
          ),
          1,
        );
        // One activity, one commit-log entry, one receipt, one outbox op, one
        // journal entry — all committed together (design.md §5).
        expect(await h.scalar('SELECT COUNT(*) FROM activity_events'), 1);
        expect(await h.scalar('SELECT COUNT(*) FROM commit_log'), 1);
        expect(await h.scalar('SELECT COUNT(*) FROM command_receipts'), 1);
        expect(
          await h.scalar(
            "SELECT COUNT(*) FROM outbox_mutations WHERE entity_type = 'task' "
            "AND op_kind = 'insert'",
          ),
          1,
        );
        expect(
          await h.scalar('SELECT COUNT(*) FROM pending_command_journal'),
          1,
        );
      },
    );

    test('replaying the same command id returns the stored result', () async {
      final CommandId cmd = h.nextCommandId('dup');
      final Result<CommittedCommandResult> first = await h.service.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateTaskInput(lifeAreaId: h.lifeAreaId, title: 'Same'),
      );
      final Result<CommittedCommandResult> second = await h.service.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateTaskInput(lifeAreaId: h.lifeAreaId, title: 'Same'),
      );
      expect(
        (first as Success<CommittedCommandResult>).value.replayed,
        isFalse,
      );
      expect(
        (second as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
      expect(second.value.resultPayload, first.value.resultPayload);
      expect(await h.scalar('SELECT COUNT(*) FROM tasks'), 1);
    });

    test('same command id with a different request is rejected', () async {
      final CommandId cmd = h.nextCommandId('conflict');
      await h.service.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateTaskInput(lifeAreaId: h.lifeAreaId, title: 'A'),
      );
      final Result<CommittedCommandResult> conflict = await h.service.create(
        commandId: cmd,
        profileId: h.profileId,
        input: CreateTaskInput(lifeAreaId: h.lifeAreaId, title: 'B'),
      );
      expect(conflict, isA<Failed<CommittedCommandResult>>());
      expect(
        (conflict as Failed<CommittedCommandResult>).failure.kind,
        FailureKind.conflict,
      );
    });

    test('attaches tags via entity_tags (R-TASK-001)', () async {
      await h.db.customStatement(
        'INSERT INTO tags (id, profile_id, normalized_name, display_name, '
        'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>['tag-1', h.profileId.value, 'work', 'Work', 0, 0],
      );
      final String id = await createTask(
        seed: 'tagged',
        tagIds: <String>['tag-1'],
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM entity_tags WHERE entity_type = 'task' "
          'AND entity_id = ? AND tag_id = ?',
          <Object?>[id, 'tag-1'],
        ),
        1,
      );
    });
  });

  group('completion is reversible and preserves metadata (R-TASK-009)', () {
    test('complete then reopen restores the actionable state', () async {
      final String id = await createTask(
        seed: 'c',
        due: TaskDue.onDate('2024-06-10'),
      );
      final TaskId taskId = TaskId(id);

      h.clock.advance(const Duration(hours: 1));
      final Result<CommittedCommandResult> completed = await h.service.complete(
        commandId: h.nextCommandId('complete'),
        profileId: h.profileId,
        taskId: taskId,
      );
      expect(completed, isA<Success<CommittedCommandResult>>());
      Task? after = await h.reads.findById(h.profileId, taskId);
      expect(after!.status, TaskStatus.completed);
      expect(after.completedAtUtc, isNotNull);
      expect(after.due.dueDate, '2024-06-10');

      final Result<CommittedCommandResult> reopened = await h.service.reopen(
        commandId: h.nextCommandId('reopen'),
        profileId: h.profileId,
        taskId: taskId,
      );
      expect(reopened, isA<Success<CommittedCommandResult>>());
      after = await h.reads.findById(h.profileId, taskId);
      expect(after!.status, TaskStatus.open);
      expect(after.completedAtUtc, isNull);
      // Original due metadata is preserved across the round trip.
      expect(after.due.dueDate, '2024-06-10');
    });

    test(
      'completing an already-completed task is an idempotent no-op',
      () async {
        final String id = await createTask(seed: 'c2');
        final TaskId taskId = TaskId(id);
        await h.service.complete(
          commandId: h.nextCommandId('c2-a'),
          profileId: h.profileId,
          taskId: taskId,
        );
        final Result<CommittedCommandResult> again = await h.service.complete(
          commandId: h.nextCommandId('c2-b'),
          profileId: h.profileId,
          taskId: taskId,
        );
        expect(
          (again as Success<CommittedCommandResult>).value.resultCode,
          'noop',
        );
      },
    );

    test('a cancelled task cannot be completed', () async {
      final String id = await createTask(seed: 'c3');
      final TaskId taskId = TaskId(id);
      await h.service.cancel(
        commandId: h.nextCommandId('cancel'),
        profileId: h.profileId,
        taskId: taskId,
      );
      final Result<CommittedCommandResult> result = await h.service.complete(
        commandId: h.nextCommandId('c3-complete'),
        profileId: h.profileId,
        taskId: taskId,
      );
      expect(result, isA<Failed<CommittedCommandResult>>());
    });
  });

  group('update (R-TASK-001, R-TASK-004, R-TASK-010)', () {
    test('switching due forms clears the previous column', () async {
      final String id = await createTask(
        seed: 'u',
        due: TaskDue.onDate('2024-06-10'),
      );
      final TaskId taskId = TaskId(id);
      await h.service.update(
        commandId: h.nextCommandId('u1'),
        profileId: h.profileId,
        taskId: taskId,
        input: UpdateTaskInput(
          due: TaskDue.atInstant(utcMicros: 5000, timezoneId: 'Europe/London'),
        ),
      );
      final Task? t = await h.reads.findById(h.profileId, taskId);
      expect(t!.due.dueDate, isNull);
      expect(t.due.dueAtUtc, 5000);
      expect(t.due.timezoneId, 'Europe/London');
    });

    test('links a canonical note reference (R-TASK-010)', () async {
      final String id = await createTask(seed: 'u2');
      final TaskId taskId = TaskId(id);
      await h.service.update(
        commandId: h.nextCommandId('u2-note'),
        profileId: h.profileId,
        taskId: taskId,
        input: UpdateTaskInput(noteId: Opt<NoteId?>(NoteId('note-9'))),
      );
      final Task? t = await h.reads.findById(h.profileId, taskId);
      expect(t!.noteId?.value, 'note-9');
    });

    test('updating a missing task fails validation', () async {
      final Result<CommittedCommandResult> result = await h.service.update(
        commandId: h.nextCommandId('u3'),
        profileId: h.profileId,
        taskId: TaskId('ghost'),
        input: const UpdateTaskInput(title: 'nope'),
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'task.not_found',
      );
    });
  });

  group('subtasks and hierarchy (R-TASK-003)', () {
    test('a subtask inherits the parent area', () async {
      final String parent = await createTask(seed: 'p');
      final String child = await createTask(seed: 'ch', parent: TaskId(parent));
      final Task? c = await h.reads.findById(h.profileId, TaskId(child));
      expect(c!.parentTaskId?.value, parent);
      expect(c.lifeAreaId.value, h.lifeAreaId.value);
    });

    test('exceeding max hierarchy depth is rejected', () async {
      String? parent;
      for (int depth = 0; depth < 5; depth += 1) {
        parent = await createTask(
          seed: 'depth-$depth',
          parent: parent == null ? null : TaskId(parent),
        );
      }
      // The 6th level exceeds TaskPolicies.maxHierarchyDepth.
      final Result<CommittedCommandResult> tooDeep = await h.service.create(
        commandId: h.nextCommandId('too-deep'),
        profileId: h.profileId,
        input: CreateTaskInput(
          lifeAreaId: h.lifeAreaId,
          title: 'too deep',
          parentTaskId: TaskId(parent!),
        ),
      );
      expect(
        (tooDeep as Failed<CommittedCommandResult>).failure.code,
        'task.hierarchy_too_deep',
      );
    });

    test('a move that creates a cycle is rejected', () async {
      final String parent = await createTask(seed: 'cy-p');
      final String child = await createTask(
        seed: 'cy-c',
        parent: TaskId(parent),
      );
      // Move the parent under its own child -> cycle.
      final Result<CommittedCommandResult> result = await h.service.move(
        commandId: h.nextCommandId('cy-move'),
        profileId: h.profileId,
        taskId: TaskId(parent),
        input: MoveTaskInput(reparent: Opt<TaskId?>(TaskId(child))),
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'task.hierarchy_cycle',
      );
    });
  });

  group('move / stable ordering (R-TASK-003)', () {
    test('reordering places a task between two neighbours', () async {
      final String a = await createTask(seed: 'o-a');
      final String b = await createTask(seed: 'o-b');
      final String c = await createTask(seed: 'o-c');
      final Task ta = (await h.reads.findById(h.profileId, TaskId(a)))!;
      final Task tc = (await h.reads.findById(h.profileId, TaskId(c)))!;
      // Move b between a and c explicitly.
      await h.service.move(
        commandId: h.nextCommandId('o-move'),
        profileId: h.profileId,
        taskId: TaskId(b),
        input: MoveTaskInput(
          beforeRank: ta.rank.value,
          afterRank: tc.rank.value,
        ),
      );
      final Task tb = (await h.reads.findById(h.profileId, TaskId(b)))!;
      expect(ta.rank.value.compareTo(tb.rank.value) < 0, isTrue);
      expect(tb.rank.value.compareTo(tc.rank.value) < 0, isTrue);
    });
  });

  group('bulk commands are atomic (R-GEN-005)', () {
    test('completeMany completes all rows under one command', () async {
      final String a = await createTask(seed: 'b-a');
      final String b = await createTask(seed: 'b-b');
      final Result<CommittedCommandResult> result = await h.service
          .completeMany(
            commandId: h.nextCommandId('bulk'),
            profileId: h.profileId,
            taskIds: <TaskId>[TaskId(a), TaskId(b)],
          );
      expect(result, isA<Success<CommittedCommandResult>>());
      expect(
        await h.scalar("SELECT COUNT(*) FROM tasks WHERE status = 'completed'"),
        2,
      );
      // One command id -> one receipt and one journal entry, two outbox ops in
      // a single semantic group.
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM command_receipts WHERE command_id = ?',
          <Object?>['cmd-bulk'],
        ),
        1,
      );
      final int groups = await h.scalar(
        'SELECT COUNT(DISTINCT group_id) FROM outbox_mutations '
        "WHERE op_kind = 'patch'",
      );
      expect(groups, 1);
    });
  });

  group('views and filters (R-TASK-002, R-TASK-008)', () {
    test(
      'inbox holds only tasks with no date; completed and trash separate',
      () async {
        final String inbox = await createTask(seed: 'v-inbox');
        final String scheduled = await createTask(
          seed: 'v-sched',
          scheduledDate: '2024-06-01',
        );
        final String done = await createTask(seed: 'v-done');
        await h.service.complete(
          commandId: h.nextCommandId('v-done-complete'),
          profileId: h.profileId,
          taskId: TaskId(done),
        );

        final List<Task> inboxView = await h.reads.view(
          h.profileId,
          TaskViewKind.inbox,
        );
        expect(inboxView.map((Task t) => t.id.value), contains(inbox));
        expect(
          inboxView.map((Task t) => t.id.value),
          isNot(contains(scheduled)),
        );
        expect(inboxView.map((Task t) => t.id.value), isNot(contains(done)));

        final List<Task> completedView = await h.reads.view(
          h.profileId,
          TaskViewKind.completed,
        );
        expect(completedView.map((Task t) => t.id.value), contains(done));
      },
    );

    test(
      'structured filter combines status and priority (R-TASK-008)',
      () async {
        await createTask(seed: 'f-low', priority: TaskPriority.low);
        final String high = await createTask(
          seed: 'f-high',
          priority: TaskPriority.high,
        );
        final List<Task> result = await h.reads.query(
          h.profileId,
          TaskQuery(
            statuses: const <TaskStatus>{TaskStatus.open},
            priorities: const <TaskPriority>{TaskPriority.high},
          ),
        );
        expect(result.map((Task t) => t.id.value), <String>[high]);
      },
    );
  });
}
