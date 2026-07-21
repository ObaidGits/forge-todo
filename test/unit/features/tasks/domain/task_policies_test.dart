import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_policies.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Overdue and hierarchy policy tests (R-TASK-004, R-TASK-003).
///
/// **Validates: Requirements R-TASK-003, R-TASK-004**
void main() {
  final int noon20240601 = DateTime.utc(2024, 6, 1, 12).microsecondsSinceEpoch;

  group('given a date-only due when evaluating overdue', () {
    test('then it is overdue once the planning day has passed', () {
      final bool overdue = TaskPolicies.isOverdue(
        status: TaskStatus.open,
        due: TaskDue.onDate('2024-05-31'),
        currentPlanningDate: '2024-06-01',
        nowUtcMicros: noon20240601,
      );
      expect(overdue, isTrue);
    });

    test('then it is not overdue on its own planning day', () {
      final bool overdue = TaskPolicies.isOverdue(
        status: TaskStatus.open,
        due: TaskDue.onDate('2024-06-01'),
        currentPlanningDate: '2024-06-01',
        nowUtcMicros: noon20240601,
      );
      expect(overdue, isFalse);
    });
  });

  group('given an instant due when evaluating overdue', () {
    test('then it is overdue when now exceeds due_at', () {
      final bool overdue = TaskPolicies.isOverdue(
        status: TaskStatus.inProgress,
        due: TaskDue.atInstant(
          utcMicros: noon20240601 - 1,
          timezoneId: 'Etc/UTC',
        ),
        currentPlanningDate: '2024-06-01',
        nowUtcMicros: noon20240601,
      );
      expect(overdue, isTrue);
    });

    test('then it is not overdue exactly at due_at', () {
      final bool overdue = TaskPolicies.isOverdue(
        status: TaskStatus.open,
        due: TaskDue.atInstant(utcMicros: noon20240601, timezoneId: 'Etc/UTC'),
        currentPlanningDate: '2024-06-01',
        nowUtcMicros: noon20240601,
      );
      expect(overdue, isFalse);
    });
  });

  group('given a terminal task when evaluating overdue', () {
    for (final TaskStatus status in <TaskStatus>[
      TaskStatus.completed,
      TaskStatus.cancelled,
    ]) {
      test('then a $status task is never overdue', () {
        final bool overdue = TaskPolicies.isOverdue(
          status: status,
          due: TaskDue.onDate('2000-01-01'),
          currentPlanningDate: '2024-06-01',
          nowUtcMicros: noon20240601,
        );
        expect(overdue, isFalse);
      });
    }
  });

  group('given a task with no due form when evaluating overdue', () {
    test('then it is never overdue', () {
      expect(
        TaskPolicies.isOverdue(
          status: TaskStatus.open,
          due: TaskDue.none,
          currentPlanningDate: '2024-06-01',
          nowUtcMicros: noon20240601,
        ),
        isFalse,
      );
    });
  });

  group('given a reparent when validating hierarchy', () {
    test('then attaching a task to its own descendant is a cycle', () {
      final HierarchyViolation? v = TaskPolicies.validateReparent(
        movingTaskId: 'a',
        ancestorChain: <String>['c', 'b', 'a'],
        descendantDepth: 1,
      );
      expect(v, HierarchyViolation.cycle);
    });

    test('then exceeding max depth is rejected', () {
      final HierarchyViolation? v = TaskPolicies.validateReparent(
        movingTaskId: 'x',
        // Parent already 5 deep; adding a 1-deep subtree makes 6 > 5.
        ancestorChain: <String>['p5', 'p4', 'p3', 'p2', 'p1'],
        descendantDepth: 1,
      );
      expect(v, HierarchyViolation.tooDeep);
    });

    test('then a legal move returns null', () {
      final HierarchyViolation? v = TaskPolicies.validateReparent(
        movingTaskId: 'x',
        ancestorChain: <String>['p1'],
        descendantDepth: 2,
      );
      expect(v, isNull);
    });
  });
}
