import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/range_selection.dart';
import 'package:forge/features/tasks/application/recurrence_command_service.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/application/task_views.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them.
// The tasks feature owns its own seams so it never imports another feature's
// presentation (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> tasksProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The tasks feature's exported read contract. Null until wired.
final Provider<TaskQueryService?> tasksQueryServiceProvider =
    Provider<TaskQueryService?>((Ref ref) => null);

/// The durable task command contract. Null until wired.
final Provider<TaskCommandService?> tasksCommandServiceProvider =
    Provider<TaskCommandService?>((Ref ref) => null);

/// The durable recurrence command contract. Null until wired.
final Provider<RecurrenceCommandService?> tasksRecurrenceServiceProvider =
    Provider<RecurrenceCommandService?>((Ref ref) => null);

/// The soft-delete / restore / purge kernel. Null until wired.
final Provider<DeletionService?> tasksDeletionServiceProvider =
    Provider<DeletionService?>((Ref ref) => null);

/// Read-only previews for destructive purge/bulk operations. Null until wired.
final Provider<PurgePreviewService?> tasksPurgePreviewServiceProvider =
    Provider<PurgePreviewService?>((Ref ref) => null);

/// Trusted clock for planning-day computation.
final Provider<Clock> tasksClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> tasksCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// A selectable Life Area for the editor. Names are decorative; the id is the
/// identifier (ux-design §5). Empty when the areas feature is not wired, in
/// which case the editor keeps a task's existing area.
final class TaskAreaOption {
  const TaskAreaOption({required this.id, required this.name});
  final LifeAreaId id;
  final String name;
}

/// The Life Areas offered by the editor. Default empty; overridden by the app.
final Provider<List<TaskAreaOption>> tasksAreaOptionsProvider =
    Provider<List<TaskAreaOption>>((Ref ref) => const <TaskAreaOption>[]);

/// The default Life Area a newly created task inherits (R-GEN-002). Null when
/// unavailable, in which case create is unavailable.
final Provider<LifeAreaId?> tasksDefaultAreaProvider = Provider<LifeAreaId?>((
  Ref ref,
) {
  final List<TaskAreaOption> options = ref.watch(tasksAreaOptionsProvider);
  return options.isEmpty ? null : options.first.id;
});

// ---------------------------------------------------------------------------
// List view + filter state.
// ---------------------------------------------------------------------------

/// The currently selected list view (R-TASK-002).
final class TaskViewController extends Notifier<TaskListView> {
  @override
  TaskListView build() => TaskListView.today;

  void set(TaskListView view) {
    if (state != view) {
      state = view;
    }
  }
}

final NotifierProvider<TaskViewController, TaskListView> taskViewProvider =
    NotifierProvider<TaskViewController, TaskListView>(TaskViewController.new);

/// The current composable filter (R-TASK-008).
final class TaskFilterController extends Notifier<TaskFilter> {
  @override
  TaskFilter build() => const TaskFilter();

  void set(TaskFilter filter) => state = filter;

  void update(TaskFilter Function(TaskFilter current) transform) =>
      state = transform(state);

  void clear() => state = const TaskFilter();

  void togglePriority(String wire) {
    final Set<String> next = Set<String>.of(state.priorityWires);
    if (!next.add(wire)) {
      next.remove(wire);
    }
    state = state.copyWith(priorityWires: next);
  }

  void toggleStatus(String wire) {
    final Set<String> next = Set<String>.of(state.statusWires);
    if (!next.add(wire)) {
      next.remove(wire);
    }
    state = state.copyWith(statusWires: next);
  }

  void setRecurrence(bool? value) =>
      state = state.copyWith(hasRecurrence: value);

  void setText(String? text) => state = state.copyWith(text: text);
}

final NotifierProvider<TaskFilterController, TaskFilter> taskFilterProvider =
    NotifierProvider<TaskFilterController, TaskFilter>(
      TaskFilterController.new,
    );

/// Loads the tasks for the current view/filter (R-TASK-002, R-TASK-008).
///
/// Reads run against the active local generation, so the list is always
/// available offline (R-GEN-001). Business rules live in the query service;
/// this controller only orchestrates and reconstructs from Drift.
final class TaskListController extends AsyncNotifier<List<TaskSummary>> {
  @override
  Future<List<TaskSummary>> build() async {
    final ProfileId? profile = ref.watch(tasksProfileProvider);
    final TaskQueryService? query = ref.watch(tasksQueryServiceProvider);
    final TaskListView view = ref.watch(taskViewProvider);
    final TaskFilter filter = ref.watch(taskFilterProvider);

    if (profile == null || query == null) {
      return const <TaskSummary>[];
    }

    final _PlanningDay day = _PlanningDay.from(ref.watch(tasksClockProvider));
    return query.list(
      profileId: profile,
      view: view,
      filter: filter,
      currentPlanningDate: day.isoDate,
      dayStartUtcMicros: day.startUtcMicros,
      nowUtcMicros: day.nowUtcMicros,
    );
  }

  /// True when the tasks feature has a wired profile + query contract.
  bool get configured =>
      ref.read(tasksProfileProvider) != null &&
      ref.read(tasksQueryServiceProvider) != null;

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<TaskListController, List<TaskSummary>>
taskListProvider = AsyncNotifierProvider<TaskListController, List<TaskSummary>>(
  TaskListController.new,
);

/// Whether the tasks read stack is wired at all (used for the empty/unavailable
/// distinction in the UI).
final Provider<bool> tasksConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(tasksProfileProvider) != null &&
      ref.watch(tasksQueryServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Multi-select state (desktop and touch; ux-design §9).
// ---------------------------------------------------------------------------

/// Transient multi-select state over the current list.
///
/// Selection uses the pure [RangeSelection] model so desktop Shift/Ctrl-click
/// range and additive behavior stays framework-free and unit-tested
/// (ux-design §9).
final class TaskSelectionState {
  const TaskSelectionState({required this.active, required this.selection});

  const TaskSelectionState.empty()
    : active = false,
      selection = const RangeSelection();

  /// Whether selection mode is engaged (a bulk action bar is shown).
  final bool active;
  final RangeSelection selection;

  Set<String> get ids => selection.ids;
  int get count => selection.count;
  bool get isEmpty => selection.isEmpty;
  bool contains(String id) => selection.contains(id);
  String? get anchor => selection.anchor;
}

final class TaskSelectionController extends Notifier<TaskSelectionState> {
  @override
  TaskSelectionState build() => const TaskSelectionState.empty();

  void enter() =>
      state = TaskSelectionState(active: true, selection: state.selection);

  void clear() => state = const TaskSelectionState.empty();

  void toggle(String id) => state = TaskSelectionState(
    active: true,
    selection: state.selection.toggle(id),
  );

  /// Applies a desktop list click with pointer [modifier] over [order]
  /// (ux-design §9): plain click selects one, Ctrl/Cmd toggles, Shift extends.
  void click(String id, List<String> order, SelectionModifier modifier) {
    state = TaskSelectionState(
      active: true,
      selection: applySelectionClick(
        current: state.selection,
        id: id,
        order: order,
        modifier: modifier,
      ),
    );
  }

  void selectAll(Iterable<String> ids) => state = TaskSelectionState(
    active: true,
    selection: const RangeSelection().selectAll(ids.toList(growable: false)),
  );

  /// Drops any selected ids no longer present after a reload.
  void pruneTo(Iterable<String> ids) {
    if (!state.active) {
      return;
    }
    state = TaskSelectionState(
      active: true,
      selection: state.selection.pruneTo(ids.toList(growable: false)),
    );
  }
}

final NotifierProvider<TaskSelectionController, TaskSelectionState>
taskSelectionProvider =
    NotifierProvider<TaskSelectionController, TaskSelectionState>(
      TaskSelectionController.new,
    );

// ---------------------------------------------------------------------------
// Mutating actions + reversible Undo feedback (R-TASK-009, R-GEN-003).
// ---------------------------------------------------------------------------

/// A reversible action the UI can offer as immediate Undo (R-GEN-003).
final class TaskUndo {
  const TaskUndo({required this.messageCode, required this.undo});

  /// Stable message code the UI maps to a localized confirmation string.
  final String messageCode;

  /// Performs the reversal. Returns the reversal result.
  final Future<Result<CommittedCommandResult>> Function() undo;
}

/// Transient feedback from the most recent action: either an Undo offer for a
/// reversible action, or a failure to surface near the command.
sealed class TaskFeedback {
  const TaskFeedback();
}

final class TaskFeedbackNone extends TaskFeedback {
  const TaskFeedbackNone();
}

final class TaskFeedbackUndo extends TaskFeedback {
  const TaskFeedbackUndo(this.offer);
  final TaskUndo offer;
}

final class TaskFeedbackError extends TaskFeedback {
  const TaskFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'tasks.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Orchestrates every task mutation over the durable command contracts and
/// records reversible Undo offers. It holds no business rules; it maps a UI
/// intent to a command, awaits the committed result, refreshes the list, and
/// exposes an Undo where the operation is reversible.
final class TaskActionsController extends Notifier<TaskFeedback> {
  @override
  TaskFeedback build() => const TaskFeedbackNone();

  void dismiss() => state = const TaskFeedbackNone();

  CommandId _id() => ref.read(tasksCommandIdFactoryProvider)();

  ProfileId? get _profile => ref.read(tasksProfileProvider);
  TaskCommandService? get _commands => ref.read(tasksCommandServiceProvider);
  DeletionService? get _deletion => ref.read(tasksDeletionServiceProvider);

  void _refresh() => ref.invalidate(taskListProvider);

  Failure? _requireWired() {
    if (_commands == null || _profile == null) {
      state = const TaskFeedbackError(_unavailableFailure);
      return _unavailableFailure;
    }
    return null;
  }

  /// Completes [taskId]; offers Undo via reopen (R-TASK-009).
  Future<Result<CommittedCommandResult>> complete(String taskId) async {
    if (_requireWired() != null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await _commands!.complete(
      commandId: _id(),
      profileId: _profile!,
      taskId: TaskId(taskId),
    );
    _afterMutation(
      result,
      undo: TaskUndo(
        messageCode: 'completed',
        undo: () => reopen(taskId, silent: true),
      ),
    );
    return result;
  }

  /// Reopens [taskId]; offers Undo via complete unless [silent].
  Future<Result<CommittedCommandResult>> reopen(
    String taskId, {
    bool silent = false,
  }) async {
    if (_requireWired() != null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await _commands!.reopen(
      commandId: _id(),
      profileId: _profile!,
      taskId: TaskId(taskId),
    );
    if (silent) {
      if (result is Success<CommittedCommandResult>) {
        _refresh();
      }
      return result;
    }
    _afterMutation(
      result,
      undo: TaskUndo(messageCode: 'reopened', undo: () => complete(taskId)),
    );
    return result;
  }

  /// Cancels [taskId] (R-TASK-003). Cancellation is not offered as Undo because
  /// the row remains recoverable through editing; destructive bulk cancel is
  /// gated by an affected-count confirmation instead (NFR-UX-002).
  Future<Result<CommittedCommandResult>> cancel(String taskId) async {
    if (_requireWired() != null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await _commands!.cancel(
      commandId: _id(),
      profileId: _profile!,
      taskId: TaskId(taskId),
    );
    _afterMutation(result);
    return result;
  }

  /// Completes many tasks as one atomic group; offers a bulk Undo (reopen each)
  /// (R-GEN-005, R-TASK-009).
  Future<Result<CommittedCommandResult>> completeMany(
    List<String> taskIds,
  ) async {
    if (_requireWired() != null || taskIds.isEmpty) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await _commands!.completeMany(
      commandId: _id(),
      profileId: _profile!,
      taskIds: taskIds.map(TaskId.new).toList(growable: false),
    );
    _afterMutation(
      result,
      undo: TaskUndo(
        messageCode: 'completedMany',
        undo: () => _reopenEach(taskIds),
      ),
    );
    return result;
  }

  /// Cancels many tasks as one atomic group (R-GEN-005). Destructive: the caller
  /// SHALL confirm the affected count first (NFR-UX-002).
  Future<Result<CommittedCommandResult>> cancelMany(
    List<String> taskIds,
  ) async {
    if (_requireWired() != null || taskIds.isEmpty) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await _commands!.cancelMany(
      commandId: _id(),
      profileId: _profile!,
      taskIds: taskIds.map(TaskId.new).toList(growable: false),
    );
    _afterMutation(result);
    return result;
  }

  /// Soft-deletes [taskId] and offers immediate Undo via restore (R-GEN-003).
  Future<Result<CommittedCommandResult>> softDelete(String taskId) async {
    final DeletionService? deletion = _deletion;
    final ProfileId? profile = _profile;
    if (deletion == null || profile == null) {
      state = const TaskFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final EntityRef ref0 = EntityRef(entityType: 'task', entityId: taskId);
    final Result<CommittedCommandResult> result = await deletion.softDelete(
      command: _deletionCommand(profile, 'task.soft_delete', <String>[taskId]),
      ref: ref0,
    );
    _afterMutation(
      result,
      undo: TaskUndo(
        messageCode: 'deleted',
        undo: () => _restore(profile, <EntityRef>[ref0]),
      ),
    );
    return result;
  }

  /// Soft-deletes many tasks as one atomic group with immediate Undo. The
  /// caller SHALL preview the affected count first (R-GEN-003, NFR-UX-002).
  Future<Result<CommittedCommandResult>> softDeleteBulk(
    List<String> taskIds,
  ) async {
    final DeletionService? deletion = _deletion;
    final ProfileId? profile = _profile;
    if (deletion == null || profile == null || taskIds.isEmpty) {
      state = const TaskFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final List<EntityRef> refs = taskIds
        .map((String id) => EntityRef(entityType: 'task', entityId: id))
        .toList(growable: false);
    final Result<CommittedCommandResult> result = await deletion.softDeleteBulk(
      command: _deletionCommand(profile, 'task.soft_delete_bulk', taskIds),
      refs: refs,
    );
    _afterMutation(
      result,
      undo: TaskUndo(
        messageCode: 'deletedMany',
        undo: () => _restore(profile, refs),
      ),
    );
    return result;
  }

  /// Restores a soft-deleted [taskId] from Trash (R-GEN-003).
  Future<Result<CommittedCommandResult>> restore(String taskId) async {
    final ProfileId? profile = _profile;
    if (_deletion == null || profile == null) {
      state = const TaskFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    return _restore(profile, <EntityRef>[
      EntityRef(entityType: 'task', entityId: taskId),
    ]);
  }

  /// Permanently purges the previewed set after explicit confirmation
  /// (R-GEN-003). Not reversible, so no Undo is offered.
  Future<Result<CommittedCommandResult>> purge({
    required List<String> taskIds,
    required PurgeConfirmation confirmation,
  }) async {
    final DeletionService? deletion = _deletion;
    final ProfileId? profile = _profile;
    if (deletion == null || profile == null) {
      state = const TaskFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await deletion.hardPurge(
      command: _deletionCommand(profile, 'task.purge', taskIds),
      refs: taskIds
          .map((String id) => EntityRef(entityType: 'task', entityId: id))
          .toList(growable: false),
      confirmation: confirmation,
    );
    _afterMutation(result);
    return result;
  }

  Future<Result<CommittedCommandResult>> _restore(
    ProfileId profile,
    List<EntityRef> refs,
  ) async {
    final DeletionService deletion = _deletion!;
    final Result<CommittedCommandResult> result = refs.length == 1
        ? await deletion.restore(
            command: _deletionCommand(profile, 'task.restore', <String>[
              refs.single.entityId,
            ]),
            ref: refs.single,
          )
        : await deletion.restoreBulk(
            command: _deletionCommand(
              profile,
              'task.restore_bulk',
              refs.map((EntityRef r) => r.entityId).toList(growable: false),
            ),
            refs: refs,
          );
    if (result is Success<CommittedCommandResult>) {
      _refresh();
    }
    return result;
  }

  Future<Result<CommittedCommandResult>> _reopenEach(
    List<String> taskIds,
  ) async {
    Result<CommittedCommandResult> last = const Failed<CommittedCommandResult>(
      _unavailableFailure,
    );
    for (final String id in taskIds) {
      last = await reopen(id, silent: true);
    }
    _refresh();
    return last;
  }

  void _afterMutation(Result<CommittedCommandResult> result, {TaskUndo? undo}) {
    switch (result) {
      case Success<CommittedCommandResult>():
        _refresh();
        ref.read(taskSelectionProvider.notifier).clear();
        state = undo == null
            ? const TaskFeedbackNone()
            : TaskFeedbackUndo(undo);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = TaskFeedbackError(failure);
    }
  }

  DurableCommand _deletionCommand(
    ProfileId profile,
    String type,
    List<String> ids,
  ) {
    final String payload = jsonEncode(<String, Object?>{
      'op': type,
      'ids': ids,
    });
    return DurableCommand(
      profileId: profile,
      commandId: _id(),
      commandType: type,
      schemaVersion: 1,
      requestHash: _stableHash(payload),
      canonicalPayload: payload,
    );
  }

  /// A compact, deterministic FNV-1a fingerprint used only to bind a command's
  /// receipt to its request (R-GEN-005); it is not a security primitive. Each
  /// deletion command already carries a fresh id, so this only guards against
  /// an accidental same-id replay with a different payload.
  static String _stableHash(String input) {
    const int prime = 0x100000001b3;
    int hash = 0xcbf29ce484222325;
    for (final int unit in utf8.encode(input)) {
      hash = (hash ^ unit) * prime;
      hash &= 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

final NotifierProvider<TaskActionsController, TaskFeedback>
taskActionsProvider = NotifierProvider<TaskActionsController, TaskFeedback>(
  TaskActionsController.new,
);

// ---------------------------------------------------------------------------
// Task detail (R-TASK-001..010).
// ---------------------------------------------------------------------------

/// Loads the detail projection for a task id. Auto-disposes when the detail
/// route is popped.
final taskDetailProvider = FutureProvider.autoDispose
    .family<TaskDetail?, String>((Ref ref, String taskId) async {
      final ProfileId? profile = ref.watch(tasksProfileProvider);
      final TaskQueryService? query = ref.watch(tasksQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      final _PlanningDay day = _PlanningDay.from(ref.watch(tasksClockProvider));
      return query.detail(
        profileId: profile,
        taskId: TaskId(taskId),
        currentPlanningDate: day.isoDate,
        nowUtcMicros: day.nowUtcMicros,
      );
    });

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

final Random _random = Random();

CommandId _defaultCommandId() {
  final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final String salt = _random.nextInt(1 << 32).toRadixString(16);
  return CommandId('cmd-$micros-$salt');
}

final class _SystemUtcClock implements Clock {
  const _SystemUtcClock();

  @override
  DateTime utcNow() => DateTime.now().toUtc();

  @override
  String timezoneId() => 'UTC';
}

/// The planning day derived from a trusted clock. The planning-day boundary is
/// user-configurable in a later wave (R-GEN-004); the tasks list uses the UTC
/// calendar day, which tests pin deterministically via a fake clock.
final class _PlanningDay {
  const _PlanningDay({
    required this.isoDate,
    required this.startUtcMicros,
    required this.nowUtcMicros,
  });

  factory _PlanningDay.from(Clock clock) {
    final DateTime nowUtc = clock.utcNow();
    final DateTime start = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final String iso =
        '${start.year.toString().padLeft(4, '0')}-'
        '${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';
    return _PlanningDay(
      isoDate: iso,
      startUtcMicros: start.microsecondsSinceEpoch,
      nowUtcMicros: nowUtc.microsecondsSinceEpoch,
    );
  }

  final String isoDate;
  final int startUtcMicros;
  final int nowUtcMicros;
}
