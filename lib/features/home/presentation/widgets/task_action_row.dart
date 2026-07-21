import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';

/// A single task row with an inline completion control (R-HOME-003, ActionRow).
///
/// The checkbox toggles completion without leaving the screen. The whole row is
/// a single semantic node with a clear name, value (checked state), and a
/// 48×48 dp hit target (NFR-A11Y-001/002).
final class TaskActionRow extends StatelessWidget {
  const TaskActionRow({
    required this.task,
    required this.onToggleComplete,
    this.busy = false,
    super.key,
  });

  final TaskSummary task;

  /// Called with the desired completion state when the user toggles the row.
  final ValueChanged<bool> onToggleComplete;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool completed = task.isCompleted;
    final String actionLabel = completed
        ? context.l10n.taskMarkIncomplete
        : context.l10n.taskMarkComplete;

    final List<String> metadata = <String>[
      if (task.isOverdue) context.l10n.taskOverdueBadge,
      if (task.dueDate != null) context.l10n.taskDueLabel(task.dueDate!),
      if (task.dueDate == null && task.scheduledDate != null)
        context.l10n.taskScheduledLabel(task.scheduledDate!),
    ];

    return Semantics(
      button: true,
      checked: completed,
      label: task.title,
      hint: actionLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: busy ? null : () => onToggleComplete(!completed),
        borderRadius: BorderRadius.circular(ForgeRadii.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: ForgeSizes.minimumInteractiveDimension,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: ForgeSpacing.xs,
              horizontal: ForgeSpacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: ForgeSizes.minimumInteractiveDimension,
                  height: ForgeSizes.minimumInteractiveDimension,
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(ForgeSpacing.sm),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Checkbox(
                          value: completed,
                          onChanged: (bool? next) =>
                              onToggleComplete(next ?? !completed),
                        ),
                ),
                const SizedBox(width: ForgeSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        task.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          decoration: completed
                              ? TextDecoration.lineThrough
                              : null,
                          color: completed
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      if (metadata.isNotEmpty) ...<Widget>[
                        const SizedBox(height: ForgeSpacing.xxs),
                        Text(
                          metadata.join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: task.isOverdue
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
