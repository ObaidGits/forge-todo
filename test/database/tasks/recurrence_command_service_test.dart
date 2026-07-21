import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/tasks/application/recurrence_commands.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

import 'recurrence_test_support.dart';

/// Real Drift-backed recurrence command tests.
///
/// **Validates: Requirements R-TASK-005, R-TASK-006, R-TASK-007, R-GEN-004,
/// R-GEN-005**
void main() {
  late RecurrenceHarness h;

  setUp(() async {
    h = await RecurrenceHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Map<String, Object?> payloadOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return jsonDecode(r.resultPayload!) as Map<String, Object?>;
  }

  Future<String> createTask({String seed = 't'}) async {
    final Result<CommittedCommandResult> result = await h.tasks.create(
      commandId: h.nextCommandId('create-$seed'),
      profileId: h.profileId,
      input: CreateTaskInput(
        lifeAreaId: h.lifeAreaId,
        title: 'Recurring $seed',
      ),
    );
    return (jsonDecode(
              (result as Success<CommittedCommandResult>).value.resultPayload!,
            )
            as Map<String, Object?>)['id']
        as String;
  }

  RecurrenceRule dailyFrom(String iso, {int interval = 1}) => RecurrenceRule(
    frequency: RecurrenceFrequency.daily,
    start: LocalDate.parse(iso),
    timezoneId: 'Etc/UTC',
    interval: interval,
  );

  group('setRecurrence (R-TASK-005)', () {
    test('creates a schedule version, first occurrence, and aligns the '
        'task due', () async {
      final String id = await createTask();
      final Result<CommittedCommandResult> result = await h.recurrence
          .setRecurrence(
            commandId: h.nextCommandId('set'),
            profileId: h.profileId,
            taskId: TaskId(id),
            input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
          );
      expect(result, isA<Success<CommittedCommandResult>>());

      expect(await h.scalar('SELECT COUNT(*) FROM recurrence_rules'), 1);
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrences WHERE status = 'open'",
        ),
        1,
      );
      final Task? task = await h.reads.findById(h.profileId, TaskId(id));
      expect(task!.recurrenceRuleId, isNotNull);
      expect(task.recurrenceVersion, 1);
      expect(task.due.dueDate, '2024-06-10');
    });

    test('rejects setting recurrence twice on one task', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set1'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      final Result<CommittedCommandResult> second = await h.recurrence
          .setRecurrence(
            commandId: h.nextCommandId('set2'),
            profileId: h.profileId,
            taskId: TaskId(id),
            input: SetRecurrenceInput(rule: dailyFrom('2024-06-11')),
          );
      expect(
        (second as Failed<CommittedCommandResult>).failure.code,
        'recurrence.already_set',
      );
    });

    test('rejects an unknown timezone', () async {
      final String id = await createTask();
      final Result<CommittedCommandResult> result = await h.recurrence
          .setRecurrence(
            commandId: h.nextCommandId('set-tz'),
            profileId: h.profileId,
            taskId: TaskId(id),
            input: SetRecurrenceInput(
              rule: RecurrenceRule(
                frequency: RecurrenceFrequency.daily,
                start: LocalDate(2024, 6, 10),
                timezoneId: 'Mars/Base',
              ),
            ),
          );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'recurrence.unknown_timezone',
      );
    });
  });

  group('completeOccurrence (R-TASK-006)', () {
    test('appends immutable history and advances to the next occurrence '
        'without rewriting the schedule version', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      final String versionBefore =
          (await h.rows('SELECT id FROM recurrence_rules')).single['id']
              as String;

      final Result<CommittedCommandResult> completed = await h.recurrence
          .completeOccurrence(
            commandId: h.nextCommandId('c1'),
            profileId: h.profileId,
            taskId: TaskId(id),
          );
      expect(payloadOf(completed)['next'], '2024-06-11');

      // History: the completed occurrence has an immutable complete event.
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrence_events "
          "WHERE event_kind = 'complete'",
        ),
        1,
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrences WHERE status = 'completed'",
        ),
        1,
      );
      // A new open occurrence was materialized for the next key.
      final List<Map<String, Object?>> open = await h.rows(
        "SELECT occurrence_key FROM task_occurrences WHERE status = 'open'",
      );
      expect(open.single['occurrence_key'], '2024-06-11');

      // The schedule version row is unchanged (same id, still one row).
      final List<Map<String, Object?>> rulesAfter = await h.rows(
        'SELECT id FROM recurrence_rules',
      );
      expect(rulesAfter.single['id'], versionBefore);

      // The task advanced its due to the next occurrence and stays actionable.
      final Task? task = await h.reads.findById(h.profileId, TaskId(id));
      expect(task!.status, TaskStatus.open);
      expect(task.due.dueDate, '2024-06-11');
    });

    test('completes the task itself when the series is exhausted', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(
          rule: RecurrenceRule(
            frequency: RecurrenceFrequency.daily,
            start: LocalDate(2024, 6, 10),
            timezoneId: 'Etc/UTC',
            end: RecurrenceEnd.count(1),
          ),
        ),
      );
      final Result<CommittedCommandResult> completed = await h.recurrence
          .completeOccurrence(
            commandId: h.nextCommandId('c1'),
            profileId: h.profileId,
            taskId: TaskId(id),
          );
      expect(
        (completed as Success<CommittedCommandResult>).value.resultCode,
        'series_completed',
      );
      final Task? task = await h.reads.findById(h.profileId, TaskId(id));
      expect(task!.status, TaskStatus.completed);
      expect(task.completedAtUtc, isNotNull);
    });
  });

  group('editRecurrence this-and-future (R-TASK-007)', () {
    test('closes the old version and creates a successor at the effective '
        'key while keeping generated history immutable', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      // Complete the first occurrence to create immutable history.
      await h.recurrence.completeOccurrence(
        commandId: h.nextCommandId('c1'),
        profileId: h.profileId,
        taskId: TaskId(id),
      );

      final Result<CommittedCommandResult> edited = await h.recurrence
          .editRecurrence(
            commandId: h.nextCommandId('edit'),
            profileId: h.profileId,
            taskId: TaskId(id),
            input: EditRecurrenceInput(
              scope: RecurrenceEditScope.thisAndFuture,
              fromOccurrenceKey: LocalDate(2024, 6, 11),
              newRule: dailyFrom('2024-06-11', interval: 2),
            ),
          );
      expect(
        (edited as Success<CommittedCommandResult>).value.resultCode,
        'recurrence_split',
      );

      // Two schedule versions now exist; the predecessor is closed.
      expect(await h.scalar('SELECT COUNT(*) FROM recurrence_rules'), 2);
      expect(
        await h.scalar(
          'SELECT COUNT(*) FROM recurrence_rules '
          'WHERE closed_at_occurrence_key IS NOT NULL',
        ),
        1,
      );
      // The completed history event is still present and unchanged.
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrence_events "
          "WHERE event_kind = 'complete'",
        ),
        1,
      );
      // The task points at the successor version (version 2).
      final Task? task = await h.reads.findById(h.profileId, TaskId(id));
      expect(task!.recurrenceVersion, 2);
      expect(task.due.dueDate, '2024-06-11');
    });
  });

  group('editRecurrence this-occurrence (R-TASK-007)', () {
    test('excludes a single occurrence and advances to the next', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      final Result<CommittedCommandResult> edited = await h.recurrence
          .editRecurrence(
            commandId: h.nextCommandId('skip'),
            profileId: h.profileId,
            taskId: TaskId(id),
            input: EditRecurrenceInput(
              scope: RecurrenceEditScope.thisOccurrence,
              fromOccurrenceKey: LocalDate(2024, 6, 10),
            ),
          );
      expect(
        (edited as Success<CommittedCommandResult>).value.resultCode,
        'occurrence_excluded',
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrences WHERE status = 'skipped'",
        ),
        1,
      );
      // The current open occurrence advanced past the excluded key.
      final List<Map<String, Object?>> open = await h.rows(
        "SELECT occurrence_key FROM task_occurrences WHERE status = 'open'",
      );
      expect(open.single['occurrence_key'], '2024-06-11');
    });
  });

  group('undoLastOccurrenceChange (R-TASK-007, R-TASK-009)', () {
    test('appends a superseding undo event and restores the prior visible '
        'state while history stays immutable', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      await h.recurrence.completeOccurrence(
        commandId: h.nextCommandId('c1'),
        profileId: h.profileId,
        taskId: TaskId(id),
      );

      final Result<CommittedCommandResult> undone = await h.recurrence
          .undoLastOccurrenceChange(
            commandId: h.nextCommandId('undo'),
            profileId: h.profileId,
            taskId: TaskId(id),
          );
      expect(
        (undone as Success<CommittedCommandResult>).value.resultCode,
        'occurrence_undone',
      );

      // The original complete event is still present (immutable) plus a new
      // superseding undo event.
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrence_events "
          "WHERE event_kind = 'complete'",
        ),
        1,
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrence_events "
          "WHERE event_kind = 'undo'",
        ),
        1,
      );
      // The restored occurrence is open again and the task due is back to it.
      final Task? task = await h.reads.findById(h.profileId, TaskId(id));
      expect(task!.due.dueDate, '2024-06-10');
    });
  });

  group('idempotent replay (R-GEN-005)', () {
    test('replaying completeOccurrence returns the stored result', () async {
      final String id = await createTask();
      await h.recurrence.setRecurrence(
        commandId: h.nextCommandId('set'),
        profileId: h.profileId,
        taskId: TaskId(id),
        input: SetRecurrenceInput(rule: dailyFrom('2024-06-10')),
      );
      final CommandId cmd = h.nextCommandId('c1');
      final Result<CommittedCommandResult> first = await h.recurrence
          .completeOccurrence(
            commandId: cmd,
            profileId: h.profileId,
            taskId: TaskId(id),
          );
      final Result<CommittedCommandResult> replay = await h.recurrence
          .completeOccurrence(
            commandId: cmd,
            profileId: h.profileId,
            taskId: TaskId(id),
          );
      expect(
        (first as Success<CommittedCommandResult>).value.replayed,
        isFalse,
      );
      expect(
        (replay as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
      // Only one completion happened despite the replay.
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM task_occurrences WHERE status = 'completed'",
        ),
        1,
      );
    });
  });

  group('DST-aware timed occurrence (R-GEN-004)', () {
    test(
      'a timed recurrence stores a UTC instant honoring the zone offset',
      () async {
        final String id = await createTask();
        await h.recurrence.setRecurrence(
          commandId: h.nextCommandId('set'),
          profileId: h.profileId,
          taskId: TaskId(id),
          input: SetRecurrenceInput(
            rule: RecurrenceRule(
              frequency: RecurrenceFrequency.daily,
              start: LocalDate(2024, 7, 15),
              timezoneId: 'America/New_York',
              timeOfDay: LocalTime(9, 0),
            ),
          ),
        );
        final Task? task = await h.reads.findById(h.profileId, TaskId(id));
        // 2024-07-15 09:00 EDT == 13:00 UTC.
        expect(task!.due.dueDate, isNull);
        expect(
          task.due.dueAtUtc,
          DateTime.utc(2024, 7, 15, 13, 0).microsecondsSinceEpoch,
        );
        expect(task.due.timezoneId, 'America/New_York');
      },
    );
  });
}
