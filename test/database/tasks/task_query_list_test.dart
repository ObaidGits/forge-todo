import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';

import 'task_test_support.dart';

/// Database-backed tests for the task list/detail query projections.
///
/// **Validates: Requirements R-TASK-002, R-TASK-004, R-TASK-008**
void main() {
  late TaskHarness h;
  late DriftTaskQueryService query;

  const String planningDate = '2024-06-15';
  final int now = DateTime.utc(2024, 6, 15, 9).microsecondsSinceEpoch;
  final int dayStart = DateTime.utc(2024, 6, 15).microsecondsSinceEpoch;

  setUp(() async {
    h = await TaskHarness.open(initialUtc: DateTime.utc(2024, 6, 15, 9));
    query = DriftTaskQueryService(h.reads);
  });

  tearDown(() async {
    await h.close();
  });

  Future<String> create(
    String seed,
    String title, {
    TaskDue due = TaskDue.none,
    TaskPriority priority = TaskPriority.none,
    String? scheduledDate,
  }) async {
    final result = await h.service.create(
      commandId: h.nextCommandId(seed),
      profileId: h.profileId,
      input: CreateTaskInput(
        lifeAreaId: h.lifeAreaId,
        title: title,
        due: due,
        priority: priority,
        scheduledDate: scheduledDate,
      ),
    );
    return (jsonDecode(result.valueOrNull!.resultPayload!)
            as Map<String, Object?>)['id']!
        as String;
  }

  Future<List<String>> titles(TaskListView view, {TaskFilter? filter}) async {
    final List<TaskSummary> list = await query.list(
      profileId: h.profileId,
      view: view,
      filter: filter ?? const TaskFilter(),
      currentPlanningDate: planningDate,
      dayStartUtcMicros: dayStart,
      nowUtcMicros: now,
    );
    return list.map((TaskSummary t) => t.title).toList();
  }

  test('today lists overdue and due-today, ordered overdue first', () async {
    await create('a', 'Overdue', due: TaskDue.onDate('2024-06-10'));
    await create('b', 'Due today', due: TaskDue.onDate('2024-06-15'));
    await create('c', 'Future', due: TaskDue.onDate('2024-06-20'));

    expect(await titles(TaskListView.today), <String>['Overdue', 'Due today']);
  });

  test('upcoming lists only future scheduled/due tasks', () async {
    await create('b', 'Due today', due: TaskDue.onDate('2024-06-15'));
    await create('c', 'Future', due: TaskDue.onDate('2024-06-20'));

    expect(await titles(TaskListView.upcoming), <String>['Future']);
  });

  test('inbox lists tasks with no date', () async {
    await create('a', 'Someday');
    await create('b', 'Due today', due: TaskDue.onDate('2024-06-15'));

    expect(await titles(TaskListView.inbox), <String>['Someday']);
  });

  test('completed lists completed tasks newest first', () async {
    final String id = await create(
      'a',
      'Done',
      due: TaskDue.onDate('2024-06-15'),
    );
    await h.service.complete(
      commandId: h.nextCommandId('complete'),
      profileId: h.profileId,
      taskId: TaskId(id),
    );

    expect(await titles(TaskListView.completed), <String>['Done']);
  });

  test('priority filter narrows a view (R-TASK-008)', () async {
    await create(
      'a',
      'Urgent',
      due: TaskDue.onDate('2024-06-15'),
      priority: TaskPriority.urgent,
    );
    await create('b', 'Normal', due: TaskDue.onDate('2024-06-15'));

    final List<String> filtered = await titles(
      TaskListView.today,
      filter: const TaskFilter(priorityWires: <String>{'urgent'}),
    );
    expect(filtered, <String>['Urgent']);
  });

  test('text filter matches on title (R-TASK-008)', () async {
    await create('a', 'Buy milk', due: TaskDue.onDate('2024-06-15'));
    await create('b', 'Call bank', due: TaskDue.onDate('2024-06-15'));

    final List<String> filtered = await titles(
      TaskListView.today,
      filter: const TaskFilter(text: 'milk'),
    );
    expect(filtered, <String>['Buy milk']);
  });

  test(
    'detail returns a full projection with overdue flag (R-TASK-004)',
    () async {
      final String id = await create(
        'a',
        'File taxes',
        due: TaskDue.onDate('2024-06-10'),
        priority: TaskPriority.high,
      );

      final TaskDetail? detail = await query.detail(
        profileId: h.profileId,
        taskId: TaskId(id),
        currentPlanningDate: planningDate,
        nowUtcMicros: now,
      );

      expect(detail, isNotNull);
      expect(detail!.title, 'File taxes');
      expect(detail.priorityWire, 'high');
      expect(detail.dueDate, '2024-06-10');
      expect(detail.isOverdue, isTrue);
      expect(detail.isRecurring, isFalse);
    },
  );

  test('detail is null for an unknown task', () async {
    final TaskDetail? detail = await query.detail(
      profileId: h.profileId,
      taskId: TaskId('018f0000-0000-7000-8000-0000deadbeef'),
    );
    expect(detail, isNull);
  });
}
