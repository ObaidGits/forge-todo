import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/core/ui/range_selection.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/presentation/task_editor_screen.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/features/tasks/presentation/widgets/task_dialogs.dart';
import 'package:forge/features/tasks/presentation/widgets/task_feedback_listener.dart';
import 'package:forge/features/tasks/presentation/widgets/task_filter_bar.dart';
import 'package:forge/features/tasks/presentation/widgets/task_list_tile.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The accessible, adaptive task list for all five views (R-TASK-002).
///
/// One screen renders Today, Upcoming, Inbox, Completed and Trash, switched by
/// the [TaskFilterBar] view chips. It supports composable filters (R-TASK-008),
/// keyboard-first multi-select with atomic bulk actions and affected-count
/// confirmations (NFR-UX-002), and immediate Undo for reversible actions
/// (R-TASK-009, R-GEN-003). All content is reconstructed from the local
/// generation, so it is available offline (R-GEN-001, R-HOME-005).
final class TaskListScreen extends ConsumerStatefulWidget {
  const TaskListScreen({
    this.initialView = TaskListView.today,
    this.initialFilter,
    super.key,
  });

  final TaskListView initialView;

  /// When set, the composable filter is applied on first build so the list
  /// opens narrowed (e.g. a recalled saved filter, R-SEARCH-002, R-TASK-008).
  /// When null the existing live filter is left untouched.
  final TaskFilter? initialFilter;

  @override
  ConsumerState<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends ConsumerState<TaskListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(taskViewProvider.notifier).set(widget.initialView);
      final TaskFilter? initialFilter = widget.initialFilter;
      if (initialFilter != null) {
        ref.read(taskFilterProvider.notifier).set(initialFilter);
      }
      ref.read(taskSelectionProvider.notifier).clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<TaskSummary>> tasks = ref.watch(taskListProvider);
    final TaskListView view = ref.watch(taskViewProvider);
    final TaskSelectionState selection = ref.watch(taskSelectionProvider);

    // Clear any live selection when the view changes.
    ref.listen<TaskListView>(taskViewProvider, (
      TaskListView? previous,
      TaskListView next,
    ) {
      ref.read(taskSelectionProvider.notifier).clear();
    });

    // Surface reversible Undo offers and errors near the command (R-GEN-003).
    ref.listen<TaskFeedback>(taskActionsProvider, (_, TaskFeedback next) {
      handleTaskFeedback(context, ref, next);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.sm,
            ForgeSpacing.md,
            0,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openEditor(context),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.taskNew),
                ),
              ),
              const SizedBox(width: ForgeSpacing.xs),
              if (!view.isTrash)
                OutlinedButton.icon(
                  onPressed: selection.active
                      ? () => ref.read(taskSelectionProvider.notifier).clear()
                      : () => ref.read(taskSelectionProvider.notifier).enter(),
                  icon: Icon(selection.active ? Icons.close : Icons.checklist),
                  label: Text(
                    selection.active ? l10n.taskSelectionExit : l10n.taskSelect,
                  ),
                ),
              if (selection.active && !view.isTrash) ...<Widget>[
                const SizedBox(width: ForgeSpacing.xs),
                TextButton.icon(
                  onPressed: () => _selectAll(ref),
                  icon: const Icon(Icons.select_all),
                  label: Text(l10n.taskSelectAll),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        const TaskFilterBar(),
        const Divider(height: 1),
        Expanded(
          child: tasks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<TaskSummary> list) =>
                _buildList(context, ref, view, list, selection),
          ),
        ),
        if (selection.active && !selection.isEmpty)
          _BulkActionBar(view: view, selection: selection),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    TaskListView view,
    List<TaskSummary> list,
    TaskSelectionState selection,
  ) {
    if (!ref.read(tasksConfiguredProvider)) {
      return _EmptyView(message: context.l10n.tasksUnavailable);
    }
    if (list.isEmpty) {
      return _EmptyView(message: _emptyMessage(context, view));
    }
    final List<String> order = list
        .map((TaskSummary t) => t.id)
        .toList(growable: false);
    return FocusTraversalGroup(
      child: ListView.separated(
        restorationId: 'content-tasks-${view.wire}',
        padding: const EdgeInsets.symmetric(
          horizontal: ForgeSpacing.xs,
          vertical: ForgeSpacing.xs,
        ),
        itemCount: list.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: ForgeSpacing.xxs),
        itemBuilder: (BuildContext context, int index) {
          final TaskSummary task = list[index];
          return ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ForgeSizes.readableContentMaxWidth,
            ),
            child: TaskListTile(
              key: ValueKey<String>('task-${task.id}'),
              task: task,
              trashed: view.isTrash,
              selectionMode: selection.active && !view.isTrash,
              selected: selection.contains(task.id),
              onToggleSelected: (bool value) =>
                  ref.read(taskSelectionProvider.notifier).toggle(task.id),
              onSelectClick: (SelectionModifier modifier) => ref
                  .read(taskSelectionProvider.notifier)
                  .click(task.id, order, modifier),
              onOpen: () => context.push('/tasks/${task.id}'),
              onToggleComplete: (bool complete) {
                final controller = ref.read(taskActionsProvider.notifier);
                unawaited(
                  complete
                      ? controller.complete(task.id)
                      : controller.reopen(task.id),
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _selectAll(WidgetRef ref) {
    final List<TaskSummary> list = switch (ref.read(taskListProvider)) {
      AsyncData<List<TaskSummary>>(:final List<TaskSummary> value) => value,
      _ => const <TaskSummary>[],
    };
    ref
        .read(taskSelectionProvider.notifier)
        .selectAll(list.map((TaskSummary t) => t.id));
  }

  Future<void> _openEditor(BuildContext context) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const TaskEditorScreen(),
        fullscreenDialog: true,
      ),
    );
    if (mounted) {
      ref.read(taskListProvider.notifier).reload();
    }
  }

  String _emptyMessage(BuildContext context, TaskListView view) {
    final AppLocalizations l10n = context.l10n;
    final bool filtered = ref.read(taskFilterProvider).activeCount > 0;
    if (filtered) {
      return l10n.tasksEmptyFiltered;
    }
    return switch (view) {
      TaskListView.today => l10n.tasksEmptyToday,
      TaskListView.upcoming => l10n.tasksEmptyUpcoming,
      TaskListView.inbox => l10n.tasksEmptyInbox,
      TaskListView.completed => l10n.tasksEmptyCompleted,
      TaskListView.trash => l10n.tasksEmptyTrash,
    };
  }
}

/// The contextual bulk action bar shown while multi-select is engaged. It
/// adapts to the current view: Trash offers Restore/Delete forever, other views
/// offer Complete/Cancel/Delete. Destructive actions preview an affected count
/// before running (NFR-UX-002).
final class _BulkActionBar extends ConsumerWidget {
  const _BulkActionBar({required this.view, required this.selection});

  final TaskListView view;
  final TaskSelectionState selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final List<String> ids = selection.ids.toList(growable: false);
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ForgeSpacing.md,
            vertical: ForgeSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.taskSelectionCount(selection.count),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (view.isTrash) ...<Widget>[
                TextButton.icon(
                  onPressed: () => _restore(ref, ids),
                  icon: const Icon(Icons.restore_from_trash),
                  label: Text(l10n.taskDetailRestore),
                ),
                TextButton.icon(
                  onPressed: () => _purge(context, ref, ids),
                  icon: const Icon(Icons.delete_forever),
                  label: Text(l10n.taskDetailDeleteForever),
                ),
              ] else ...<Widget>[
                TextButton.icon(
                  onPressed: () => unawaited(
                    ref.read(taskActionsProvider.notifier).completeMany(ids),
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(l10n.taskBulkComplete),
                ),
                TextButton.icon(
                  onPressed: () => _confirmCancel(context, ref, ids),
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(l10n.taskBulkCancel),
                ),
                TextButton.icon(
                  onPressed: () => _confirmDelete(context, ref, ids),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.taskBulkDelete),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showTaskConfirm(
      context: context,
      title: l10n.taskConfirmDeleteTitle,
      body: l10n.taskConfirmDeleteBody(ids.length),
      confirmLabel: l10n.taskConfirmDelete,
    );
    if (ok) {
      await ref.read(taskActionsProvider.notifier).softDeleteBulk(ids);
    }
  }

  Future<void> _confirmCancel(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showTaskConfirm(
      context: context,
      title: l10n.taskConfirmCancelTitle,
      body: l10n.taskConfirmCancelBody(ids.length),
      confirmLabel: l10n.taskConfirmCancelConfirm,
    );
    if (ok) {
      await ref.read(taskActionsProvider.notifier).cancelMany(ids);
    }
  }

  void _restore(WidgetRef ref, List<String> ids) {
    final controller = ref.read(taskActionsProvider.notifier);
    for (final String id in ids) {
      unawaited(controller.restore(id));
    }
    ref.read(taskSelectionProvider.notifier).clear();
  }

  Future<void> _purge(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final AppLocalizations l10n = context.l10n;
    final PurgePreviewService? previewService = ref.read(
      tasksPurgePreviewServiceProvider,
    );
    final ProfileId? profile = ref.read(tasksProfileProvider);
    if (previewService == null || profile == null) {
      return;
    }
    final PurgePreview preview = await previewService.previewPurge(
      profile,
      ids
          .map((String id) => EntityRef(entityType: 'task', entityId: id))
          .toList(growable: false),
    );
    if (!context.mounted) {
      return;
    }
    if (preview.affectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            preview.hasBlocked
                ? l10n.taskPurgeBlocked(preview.blockedCount)
                : l10n.taskPurgeNothing,
          ),
        ),
      );
      return;
    }
    final String body = preview.hasBlocked
        ? '${l10n.taskPurgeBody(preview.affectedCount)} '
              '${l10n.taskPurgeBlocked(preview.blockedCount)}'
        : l10n.taskPurgeBody(preview.affectedCount);
    final bool ok = await showTaskConfirm(
      context: context,
      title: l10n.taskPurgeTitle,
      body: body,
      confirmLabel: l10n.taskPurgeConfirm,
    );
    if (!ok) {
      return;
    }
    await ref
        .read(taskActionsProvider.notifier)
        .purge(
          taskIds: preview.purgeableRefs
              .map((EntityRef r) => r.entityId)
              .toList(growable: false),
          confirmation: preview.confirmation,
        );
    ref.read(taskSelectionProvider.notifier).clear();
  }
}

final class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
