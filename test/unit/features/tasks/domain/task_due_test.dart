import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Due-form and entity invariant tests (R-TASK-004).
///
/// **Validates: Requirements R-TASK-004**
void main() {
  Task buildTask({
    TaskStatus status = TaskStatus.open,
    TaskDue due = TaskDue.none,
    int? completedAtUtc,
  }) => Task(
    id: TaskId('t1'),
    profileId: ProfileId('p1'),
    lifeAreaId: LifeAreaId('a1'),
    title: 'Write spec',
    status: status,
    priority: TaskPriority.none,
    due: due,
    rank: TaskRank.initial,
    createdAtUtc: 0,
    updatedAtUtc: 0,
    completedAtUtc: completedAtUtc,
  );

  test('a date-only due exposes only the date', () {
    final TaskDue due = TaskDue.onDate('2024-06-01');
    expect(due.dueDate, '2024-06-01');
    expect(due.dueAtUtc, isNull);
    expect(due.timezoneId, isNull);
    expect(due.hasDue, isTrue);
  });

  test('an instant due exposes the instant and timezone only', () {
    final TaskDue due = TaskDue.atInstant(
      utcMicros: 1000,
      timezoneId: 'Europe/London',
    );
    expect(due.dueAtUtc, 1000);
    expect(due.timezoneId, 'Europe/London');
    expect(due.dueDate, isNull);
  });

  test('a malformed date is rejected', () {
    expect(() => TaskDue.onDate('2024-6-1'), throwsFormatException);
  });

  test('an instant due requires a timezone', () {
    expect(
      () => TaskDue.atInstant(utcMicros: 1, timezoneId: ''),
      throwsFormatException,
    );
  });

  test('an empty title is rejected', () {
    expect(
      () => Task(
        id: TaskId('t1'),
        profileId: ProfileId('p1'),
        lifeAreaId: LifeAreaId('a1'),
        title: '   ',
        status: TaskStatus.open,
        priority: TaskPriority.none,
        due: TaskDue.none,
        rank: TaskRank.initial,
        createdAtUtc: 0,
        updatedAtUtc: 0,
      ),
      throwsFormatException,
    );
  });

  test('a completed task requires a completion instant', () {
    expect(
      () => buildTask(status: TaskStatus.completed),
      throwsFormatException,
    );
    expect(
      buildTask(status: TaskStatus.completed, completedAtUtc: 5).completedAtUtc,
      5,
    );
  });

  test('a non-terminal task cannot carry a completion instant', () {
    expect(
      () => buildTask(status: TaskStatus.open, completedAtUtc: 5),
      throwsFormatException,
    );
  });
}
