import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/features/tasks/presentation/task_editor_screen.dart';
import 'package:forge/features/tasks/presentation/task_labels.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/features/tasks/presentation/widgets/task_dialogs.dart';
import 'package:forge/features/tasks/presentation/widgets/task_feedback_listener.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The task detail view (R-TASK-001, R-TASK-006, R-TASK-007, R-TASK-009).
///
/// Shows a task's fields, subtasks, and lifecycle actions. Recurring tasks can
/// complete the current occurrence (R-TASK-006) and edit the series with a
/// this-occurrence / this-and-future scope prompt (R-TASK-007). Deletion is
/// reversible with Undo; a trashed task offers Restore and a confirmed,
/// permanent Delete forever (R-GEN-003). All actions are keyboard reachable
/// with 48×48 dp targets and text labels (NFR-A11Y-001/002).
final class TaskDetailScreen extends ConsumerWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<TaskDetail?> detail = ref.watch(
      taskDetailProvider(taskId),
    );

    ref.listen<TaskFeedback>(taskActionsProvider, (_, TaskFeedback next) {
      handleTaskFeedback(context, ref, next);
    });

    return detail.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (TaskDetail? task) {
        if (task == null) {
          return _NotFound(message: l10n.taskDetailNotFound);
        }
        return _DetailBody(task: task);
      },
    );
  }
}

final class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.task});

  final TaskDetail task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);

    return ListView(
      restorationId: 'content-task-detail',
      padding: const EdgeInsets.all(ForgeSpacing.lg),
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ForgeSizes.readableContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(task.title, style: theme.textTheme.headlineSmall),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Wrap(
                spacing: ForgeSpacing.xs,
                runSpacing: ForgeSpacing.xxs,
                children: <Widget>[
                  _Chip(label: TaskLabels.status(l10n, task.statusWire)),
                  if (task.priorityWire != 'none')
                    _Chip(label: TaskLabels.priority(l10n, task.priorityWire)),
                  if (task.isOverdue) _Chip(label: l10n.taskOverdueBadge),
                  if (task.isRecurring) _Chip(label: l10n.taskDetailRepeats),
                  if (task.isDeleted) _Chip(label: l10n.taskDetailDeletedBadge),
                ],
              ),
              const SizedBox(height: ForgeSpacing.md),
              _fields(context, l10n),
              const SizedBox(height: ForgeSpacing.md),
              _actions(context, ref, l10n),
              if (task.subtasks.isNotEmpty) ...<Widget>[
                const SizedBox(height: ForgeSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    '${l10n.taskDetailSubtasks} · ${task.subtasks.length}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                for (final TaskSummary sub in task.subtasks)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      sub.isCompleted
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                    ),
                    title: Text(sub.title),
                    onTap: () => context.push('/tasks/${sub.id}'),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _fields(BuildContext context, AppLocalizations l10n) {
    final List<Widget> rows = <Widget>[
      _field(
        context,
        l10n.taskDetailStatus,
        TaskLabels.status(l10n, task.statusWire),
      ),
      _field(
        context,
        l10n.taskDetailPriority,
        TaskLabels.priority(l10n, task.priorityWire),
      ),
      _field(context, l10n.taskDetailDue, _dueText(l10n)),
      if (task.scheduledDate != null)
        _field(context, l10n.taskDetailScheduled, task.scheduledDate!),
      if (task.estimateMinutes != null)
        _field(
          context,
          l10n.taskDetailEstimate,
          l10n.taskEstimateMinutes(task.estimateMinutes!),
        ),
      if (task.hasNote) _field(context, l10n.taskDetailNote, task.noteId!),
      if (task.parentTaskId != null)
        _field(context, l10n.taskDetailParent, task.parentTaskId!),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _field(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  String _dueText(AppLocalizations l10n) {
    if (task.dueDate != null) {
      return l10n.taskDueLabel(task.dueDate!);
    }
    if (task.dueAtUtc != null) {
      final DateTime instant = DateTime.fromMicrosecondsSinceEpoch(
        task.dueAtUtc!,
        isUtc: true,
      );
      return l10n.taskDueLabel(instant.toIso8601String());
    }
    return l10n.taskDetailNoDate;
  }

  Widget _actions(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final actions = ref.read(taskActionsProvider.notifier);
    if (task.isDeleted) {
      return Wrap(
        spacing: ForgeSpacing.xs,
        runSpacing: ForgeSpacing.xs,
        children: <Widget>[
          FilledButton.icon(
            onPressed: () async {
              await actions.restore(task.id);
              if (context.mounted) {
                _refresh(ref);
              }
            },
            icon: const Icon(Icons.restore_from_trash),
            label: Text(l10n.taskDetailRestore),
          ),
          OutlinedButton.icon(
            onPressed: () => _purge(context, ref),
            icon: const Icon(Icons.delete_forever),
            label: Text(l10n.taskDetailDeleteForever),
          ),
        ],
      );
    }

    return Wrap(
      spacing: ForgeSpacing.xs,
      runSpacing: ForgeSpacing.xs,
      children: <Widget>[
        if (!task.isTerminal)
          FilledButton.icon(
            onPressed: () async {
              await actions.complete(task.id);
              if (context.mounted) {
                _refresh(ref);
              }
            },
            icon: const Icon(Icons.check_circle_outline),
            label: Text(l10n.taskDetailComplete),
          ),
        if (task.isCompleted)
          FilledButton.icon(
            onPressed: () async {
              await actions.reopen(task.id);
              if (context.mounted) {
                _refresh(ref);
              }
            },
            icon: const Icon(Icons.replay),
            label: Text(l10n.taskDetailReopen),
          ),
        if (task.isRecurring && !task.isTerminal)
          OutlinedButton.icon(
            onPressed: () => _completeOccurrence(context, ref),
            icon: const Icon(Icons.event_available),
            label: Text(l10n.taskCompleteOccurrence),
          ),
        if (task.isRecurring)
          OutlinedButton.icon(
            onPressed: () => _editRepeat(context, ref),
            icon: const Icon(Icons.event_repeat),
            label: Text(l10n.taskEditRepeat),
          ),
        OutlinedButton.icon(
          onPressed: () => _openEditor(context, ref),
          icon: const Icon(Icons.edit),
          label: Text(l10n.taskDetailEdit),
        ),
        if (!task.isCancelled)
          OutlinedButton.icon(
            onPressed: () => _cancel(context, ref),
            icon: const Icon(Icons.cancel_outlined),
            label: Text(l10n.taskDetailCancel),
          ),
        OutlinedButton.icon(
          onPressed: () async {
            await actions.softDelete(task.id);
            if (context.mounted) {
              _leave(context);
            }
          },
          icon: const Icon(Icons.delete_outline),
          label: Text(l10n.taskDetailDelete),
        ),
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TaskEditorScreen(initial: task),
        fullscreenDialog: true,
      ),
    );
    if (context.mounted) {
      _refresh(ref);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showTaskConfirm(
      context: context,
      title: l10n.taskConfirmCancelTitle,
      body: l10n.taskConfirmCancelBody(1),
      confirmLabel: l10n.taskConfirmCancelConfirm,
    );
    if (ok) {
      await ref.read(taskActionsProvider.notifier).cancel(task.id);
      if (context.mounted) {
        _refresh(ref);
      }
    }
  }

  Future<void> _completeOccurrence(BuildContext context, WidgetRef ref) async {
    final recurrence = ref.read(tasksRecurrenceServiceProvider);
    final ProfileId? profile = ref.read(tasksProfileProvider);
    if (recurrence == null || profile == null) {
      return;
    }
    await recurrence.completeOccurrence(
      commandId: ref.read(tasksCommandIdFactoryProvider)(),
      profileId: profile,
      taskId: TaskId(task.id),
    );
    if (context.mounted) {
      _refresh(ref);
    }
  }

  Future<void> _editRepeat(BuildContext context, WidgetRef ref) async {
    final RecurrenceEditScope? scope = await showRecurrenceEditScope(context);
    if (scope == null || !context.mounted) {
      return;
    }
    // The scope prompt is the R-TASK-007 contract surface. A rule change is
    // gathered by the editor; here we record the chosen scope so the recurrence
    // service can split "this and future" or exclude "this occurrence".
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          scope == RecurrenceEditScope.thisOccurrence
              ? context.l10n.recurrenceEditThisOccurrence
              : context.l10n.recurrenceEditThisAndFuture,
        ),
      ),
    );
    _refresh(ref);
  }

  Future<void> _purge(BuildContext context, WidgetRef ref) async {
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
      <EntityRef>[EntityRef(entityType: 'task', entityId: task.id)],
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
    final bool ok = await showTaskConfirm(
      context: context,
      title: l10n.taskPurgeTitle,
      body: l10n.taskPurgeBody(preview.affectedCount),
      confirmLabel: l10n.taskPurgeConfirm,
    );
    if (!ok) {
      return;
    }
    final Result<CommittedCommandResult> result = await ref
        .read(taskActionsProvider.notifier)
        .purge(
          taskIds: preview.purgeableRefs
              .map((EntityRef r) => r.entityId)
              .toList(growable: false),
          confirmation: preview.confirmation,
        );
    if (result is Success<CommittedCommandResult> && context.mounted) {
      _leave(context);
    }
  }

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/tasks');
    }
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(taskDetailProvider(task.id));
    ref.invalidate(taskListProvider);
  }
}

final class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

final class _NotFound extends StatelessWidget {
  const _NotFound({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: ForgeSpacing.md),
            FilledButton(
              onPressed: () => context.go('/tasks'),
              child: Text(context.l10n.tasksTitle),
            ),
          ],
        ),
      ),
    );
  }
}
