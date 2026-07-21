import 'package:forge/core/domain/id.dart';

/// A named task list view (R-TASK-002).
///
/// These are the presentation-safe view kinds the list screen offers. They mirror
/// the domain `TaskViewKind` but live in the application boundary so the
/// presentation layer never imports the tasks domain.
enum TaskListView {
  /// Overdue plus tasks scheduled or due today.
  today,

  /// Future scheduled/due tasks.
  upcoming,

  /// Tasks with neither a scheduled date nor a due form.
  inbox,

  /// Completed tasks, newest completion first.
  completed,

  /// Soft-deleted tasks (Trash).
  trash;

  /// Stable wire/route token, e.g. used in analytics-free route mapping.
  String get wire => name;

  /// Whether this view lists soft-deleted rows rather than live ones.
  bool get isTrash => this == TaskListView.trash;

  /// Whether the view needs a planning date / trusted now to classify tasks.
  bool get needsClock =>
      this == TaskListView.today || this == TaskListView.upcoming;

  static TaskListView fromWire(String wire) {
    for (final TaskListView view in TaskListView.values) {
      if (view.wire == wire) {
        return view;
      }
    }
    return TaskListView.today;
  }
}

/// A relation filter over another entity, expressed with primitive wire values
/// so the presentation layer stays free of the tasks domain (R-TASK-008).
final class TaskRelationRef {
  const TaskRelationRef({
    required this.relation,
    required this.targetType,
    required this.targetId,
  });

  /// The link relation, e.g. `belongs_to_goal`, `supports_habit`.
  final String relation;
  final String targetType;
  final String targetId;

  @override
  bool operator ==(Object other) =>
      other is TaskRelationRef &&
      other.relation == relation &&
      other.targetType == targetType &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(relation, targetType, targetId);
}

/// A composable, presentation-safe task filter (R-TASK-008).
///
/// Every field is optional and combined with logical AND. All values are
/// primitives or core ID types, so the list controller and filter bar never
/// touch the tasks domain model. The Drift query service maps this to the
/// domain `TaskQuery`.
final class TaskFilter {
  const TaskFilter({
    this.statusWires = const <String>{},
    this.priorityWires = const <String>{},
    this.lifeAreaId,
    this.tagId,
    this.hasRecurrence,
    this.relation,
    this.text,
    this.dueFromDate,
    this.dueToDate,
  });

  /// Selected status wire values (`open`, `in_progress`, ...). Empty = any.
  final Set<String> statusWires;

  /// Selected priority wire values (`none`..`urgent`). Empty = any.
  final Set<String> priorityWires;

  final LifeAreaId? lifeAreaId;
  final String? tagId;

  /// When set, restricts to tasks that are (true) or are not (false) recurring.
  final bool? hasRecurrence;

  final TaskRelationRef? relation;

  /// Free-text substring match over the title.
  final String? text;

  /// Inclusive floating-date range over `due_date` (`YYYY-MM-DD`).
  final String? dueFromDate;
  final String? dueToDate;

  bool get isEmpty =>
      statusWires.isEmpty &&
      priorityWires.isEmpty &&
      lifeAreaId == null &&
      tagId == null &&
      hasRecurrence == null &&
      relation == null &&
      (text == null || text!.trim().isEmpty) &&
      dueFromDate == null &&
      dueToDate == null;

  /// The number of active facets, used for the always-visible filter summary.
  int get activeCount {
    int count = 0;
    if (statusWires.isNotEmpty) count++;
    if (priorityWires.isNotEmpty) count++;
    if (lifeAreaId != null) count++;
    if (tagId != null) count++;
    if (hasRecurrence != null) count++;
    if (relation != null) count++;
    if (text != null && text!.trim().isNotEmpty) count++;
    if (dueFromDate != null || dueToDate != null) count++;
    return count;
  }

  TaskFilter copyWith({
    Set<String>? statusWires,
    Set<String>? priorityWires,
    Object? lifeAreaId = _sentinel,
    Object? tagId = _sentinel,
    Object? hasRecurrence = _sentinel,
    Object? relation = _sentinel,
    Object? text = _sentinel,
    Object? dueFromDate = _sentinel,
    Object? dueToDate = _sentinel,
  }) {
    return TaskFilter(
      statusWires: statusWires ?? this.statusWires,
      priorityWires: priorityWires ?? this.priorityWires,
      lifeAreaId: lifeAreaId == _sentinel
          ? this.lifeAreaId
          : lifeAreaId as LifeAreaId?,
      tagId: tagId == _sentinel ? this.tagId : tagId as String?,
      hasRecurrence: hasRecurrence == _sentinel
          ? this.hasRecurrence
          : hasRecurrence as bool?,
      relation: relation == _sentinel
          ? this.relation
          : relation as TaskRelationRef?,
      text: text == _sentinel ? this.text : text as String?,
      dueFromDate: dueFromDate == _sentinel
          ? this.dueFromDate
          : dueFromDate as String?,
      dueToDate: dueToDate == _sentinel ? this.dueToDate : dueToDate as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TaskFilter &&
      _setEq(other.statusWires, statusWires) &&
      _setEq(other.priorityWires, priorityWires) &&
      other.lifeAreaId == lifeAreaId &&
      other.tagId == tagId &&
      other.hasRecurrence == hasRecurrence &&
      other.relation == relation &&
      other.text == text &&
      other.dueFromDate == dueFromDate &&
      other.dueToDate == dueToDate;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(statusWires),
    Object.hashAllUnordered(priorityWires),
    lifeAreaId,
    tagId,
    hasRecurrence,
    relation,
    text,
    dueFromDate,
    dueToDate,
  );

  static bool _setEq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static const Object _sentinel = Object();
}
