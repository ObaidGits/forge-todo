import 'dart:convert';

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/home/application/home_query_service.dart';
import 'package:forge/features/home/infrastructure/settings_home_layout_store.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';

import '../tasks/task_test_support.dart';

/// Composes the full Home read stack over a real Drift database: the tasks
/// command service (for capture/completion), the tasks query contract, the Home
/// query facade, and the durable settings-backed layout store.
final class HomeHarness {
  HomeHarness._(
    this.tasks,
    this.queryService,
    this.homeQuery,
    this.layoutStore,
  );

  static Future<HomeHarness> open({DateTime? initialUtc}) async {
    final TaskHarness tasks = await TaskHarness.open(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 15, 9),
    );
    final DriftTaskQueryService query = DriftTaskQueryService(tasks.reads);
    return HomeHarness._(
      tasks,
      query,
      HomeQueryService(query),
      SettingsHomeLayoutStore(tasks.db, tasks.clock),
    );
  }

  final TaskHarness tasks;
  final TaskQueryService queryService;
  final HomeQueryService homeQuery;
  final SettingsHomeLayoutStore layoutStore;

  ProfileId get profileId => tasks.profileId;

  /// The planning day pinned by the fake clock (UTC calendar day).
  String get planningDate {
    final DateTime now = tasks.clock.utcNow();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  int get dayStartUtcMicros {
    final DateTime now = tasks.clock.utcNow();
    return DateTime.utc(now.year, now.month, now.day).microsecondsSinceEpoch;
  }

  int get nowUtcMicros => tasks.clock.utcNow().microsecondsSinceEpoch;

  Future<String> createTask({
    required String seed,
    required String title,
    TaskDue due = TaskDue.none,
    TaskPriority priority = TaskPriority.none,
    String? scheduledDate,
  }) async {
    final Result<CommittedCommandResult> result = await tasks.service.create(
      commandId: tasks.nextCommandId(seed),
      profileId: profileId,
      input: CreateTaskInput(
        lifeAreaId: tasks.lifeAreaId,
        title: title,
        due: due,
        priority: priority,
        scheduledDate: scheduledDate,
      ),
    );
    return _idOf(result);
  }

  Future<void> completeTask({required String seed, required String taskId}) {
    return tasks.service.complete(
      commandId: tasks.nextCommandId(seed),
      profileId: profileId,
      taskId: TaskId(taskId),
    );
  }

  Future<void> close() => tasks.close();

  static String _idOf(Result<CommittedCommandResult> result) {
    final CommittedCommandResult committed =
        (result as Success<CommittedCommandResult>).value;
    final Map<String, Object?> payload =
        jsonDecode(committed.resultPayload!) as Map<String, Object?>;
    return payload['id']! as String;
  }
}
