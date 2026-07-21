import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

/// Pure task policies with no persistence or platform dependencies.
abstract final class TaskPolicies {
  /// The maximum depth of the subtask hierarchy (R-TASK-003 "bounded acyclic
  /// hierarchy"). Depth 1 is a top-level task; the deepest allowed subtask sits
  /// at [maxHierarchyDepth].
  static const int maxHierarchyDepth = 5;

  /// Whether a task is overdue (R-TASK-004).
  ///
  /// * A completed or cancelled task is never overdue.
  /// * A floating date-only task is overdue once the planning-day boundary has
  ///   passed after its due date, expressed here as the current planning date
  ///   ([currentPlanningDate], an ISO `YYYY-MM-DD`) being strictly after the
  ///   due date. The caller resolves the planning-day boundary into that date.
  /// * An instant task is overdue when the trusted current time
  ///   ([nowUtcMicros]) exceeds its `due_at`.
  static bool isOverdue({
    required TaskStatus status,
    required TaskDue due,
    required String currentPlanningDate,
    required int nowUtcMicros,
  }) {
    if (status.isTerminal) {
      return false;
    }
    return switch (due) {
      NoDue() => false,
      DateDue(:final String date) => currentPlanningDate.compareTo(date) > 0,
      InstantDue(:final int utcMicros) => nowUtcMicros > utcMicros,
    };
  }

  /// Validates that moving a task under [prospectiveParentId] keeps the
  /// hierarchy acyclic and within [maxHierarchyDepth].
  ///
  /// [ancestorChain] is the chain of ids from the prospective parent upward to
  /// the root, *including* the prospective parent itself as the first element.
  /// [descendantDepth] is the depth of the moving task's own subtree (1 when it
  /// has no children). Returns a [HierarchyViolation] describing the first
  /// problem, or null when the move is legal.
  static HierarchyViolation? validateReparent({
    required String movingTaskId,
    required List<String> ancestorChain,
    required int descendantDepth,
  }) {
    if (ancestorChain.contains(movingTaskId)) {
      return HierarchyViolation.cycle;
    }
    // Parent depth is its distance from the root: chain length. Attaching the
    // moving subtree adds [descendantDepth] more levels below the parent.
    final int resultingDepth = ancestorChain.length + descendantDepth;
    if (resultingDepth > maxHierarchyDepth) {
      return HierarchyViolation.tooDeep;
    }
    return null;
  }
}

/// Why a reparent/subtask attachment is rejected.
enum HierarchyViolation {
  /// The move would create a cycle (a task cannot descend from itself).
  cycle,

  /// The move would exceed [TaskPolicies.maxHierarchyDepth].
  tooDeep,
}
