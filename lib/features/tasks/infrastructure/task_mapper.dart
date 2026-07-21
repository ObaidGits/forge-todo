import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Explicit mapping between the `tasks` Drift row and the immutable [Task]
/// domain aggregate (design.md "Data Models").
abstract final class TaskMapper {
  /// Rebuilds a [Task] from a persisted row, reconstructing the due form from
  /// the mutually exclusive `due_date` / `due_at_utc` columns.
  static Task fromRow(TaskRow row) {
    final TaskDue due;
    if (row.dueAtUtc != null) {
      due = InstantDue(
        utcMicros: row.dueAtUtc!,
        timezoneId: row.dueTimezone ?? 'Etc/UTC',
      );
    } else if (row.dueDate != null) {
      due = DateDue(row.dueDate!);
    } else {
      due = TaskDue.none;
    }
    return Task(
      id: TaskId(row.id),
      profileId: ProfileId(row.profileId),
      lifeAreaId: LifeAreaId(row.lifeAreaId),
      parentTaskId: row.parentTaskId == null ? null : TaskId(row.parentTaskId!),
      title: row.title,
      status: TaskStatus.fromWire(row.status),
      priority: TaskPriority.fromWire(row.priority),
      scheduledDate: row.scheduledDate,
      due: due,
      estimateMinutes: row.estimateMinutes,
      recurrenceRuleId: row.recurrenceRuleId,
      recurrenceVersion: row.recurrenceVersion,
      completedAtUtc: row.completedAtUtc,
      noteId: row.noteId == null ? null : NoteId(row.noteId!),
      rank: TaskRank(row.rank),
      revision: row.revision,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      deletedAtUtc: row.deletedAtUtc,
    );
  }

  /// Builds an insert companion for a new [task].
  static TasksCompanion toInsert(Task task) => TasksCompanion.insert(
    id: task.id.value,
    profileId: task.profileId.value,
    lifeAreaId: task.lifeAreaId.value,
    parentTaskId: Value<String?>(task.parentTaskId?.value),
    title: task.title,
    status: task.status.wire,
    priority: task.priority.wire,
    scheduledDate: Value<String?>(task.scheduledDate),
    dueDate: Value<String?>(task.due.dueDate),
    dueAtUtc: Value<int?>(task.due.dueAtUtc),
    dueTimezone: Value<String?>(task.due.timezoneId),
    estimateMinutes: Value<int?>(task.estimateMinutes),
    recurrenceRuleId: Value<String?>(task.recurrenceRuleId),
    recurrenceVersion: Value<int?>(task.recurrenceVersion),
    completedAtUtc: Value<int?>(task.completedAtUtc),
    noteId: Value<String?>(task.noteId?.value),
    rank: task.rank.value,
    revision: Value<int>(task.revision),
    createdAtUtc: task.createdAtUtc,
    updatedAtUtc: task.updatedAtUtc,
    deletedAtUtc: Value<int?>(task.deletedAtUtc),
  );

  /// Builds a full-row update companion for an existing [task]. Every mutable
  /// column is written so the row exactly matches the aggregate; the due form
  /// columns are always set (possibly to null) so switching due forms clears
  /// the other column.
  static TasksCompanion toUpdate(Task task) => TasksCompanion(
    lifeAreaId: Value<String>(task.lifeAreaId.value),
    parentTaskId: Value<String?>(task.parentTaskId?.value),
    title: Value<String>(task.title),
    status: Value<String>(task.status.wire),
    priority: Value<String>(task.priority.wire),
    scheduledDate: Value<String?>(task.scheduledDate),
    dueDate: Value<String?>(task.due.dueDate),
    dueAtUtc: Value<int?>(task.due.dueAtUtc),
    dueTimezone: Value<String?>(task.due.timezoneId),
    estimateMinutes: Value<int?>(task.estimateMinutes),
    recurrenceRuleId: Value<String?>(task.recurrenceRuleId),
    recurrenceVersion: Value<int?>(task.recurrenceVersion),
    completedAtUtc: Value<int?>(task.completedAtUtc),
    noteId: Value<String?>(task.noteId?.value),
    rank: Value<String>(task.rank.value),
    revision: Value<int>(task.revision),
    updatedAtUtc: Value<int>(task.updatedAtUtc),
    deletedAtUtc: Value<int?>(task.deletedAtUtc),
  );
}
