import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/core/ui/range_selection.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/presentation/task_labels.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A single task row for the list views (ActionRow, R-TASK-002).
///
/// The row is one semantic node with a clear name, checked/selected value, and
/// a 48×48 dp hit target (NFR-A11Y-001/002). It renders in three modes:
///
/// * default — leading completion checkbox, tap opens the task;
/// * multi-select — leading selection checkbox, tap toggles selection;
/// * trash — no completion control (a deleted task is not actionable).
///
/// Color is never the sole signal: overdue, priority and status are always
/// accompanied by a text label (ux-design §5).
final class TaskListTile extends StatelessWidget {
  const TaskListTile({
    required this.task,
    required this.onOpen,
    required this.onToggleComplete,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
    this.onSelectClick,
    this.trashed = false,
    this.busy = false,
    super.key,
  });

  final TaskSummary task;
  final VoidCallback onOpen;
  final ValueChanged<bool> onToggleComplete;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onToggleSelected;

  /// Desktop row click while in selection mode, carrying the active pointer
  /// modifier (Shift = range, Ctrl/Cmd = toggle, none = select one). When null
  /// the row falls back to a plain toggle (touch behavior).
  final ValueChanged<SelectionModifier>? onSelectClick;
  final bool trashed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = context.l10n;
    final bool completed = task.isCompleted;

    final List<String> metadata = <String>[
      if (task.isOverdue) l10n.taskOverdueBadge,
      if (task.priorityWire != 'none')
        TaskLabels.priority(l10n, task.priorityWire),
      if (task.dueDate != null) l10n.taskDueLabel(task.dueDate!),
      if (task.dueDate == null && task.scheduledDate != null)
        l10n.taskScheduledLabel(task.scheduledDate!),
    ];

    final String semanticName = <String>[task.title, ...metadata].join(', ');

    void handleTap() {
      if (selectionMode) {
        if (onSelectClick case final ValueChanged<SelectionModifier> click) {
          click(_activeModifier());
        } else {
          onToggleSelected?.call(!selected);
        }
      } else {
        onOpen();
      }
    }

    return Semantics(
      button: true,
      selected: selectionMode ? selected : null,
      checked: selectionMode ? null : (trashed ? null : completed),
      label: semanticName,
      hint: selectionMode
          ? l10n.taskSelect
          : (trashed ? l10n.taskOpenDetail : l10n.taskOpenDetail),
      excludeSemantics: true,
      child: InkWell(
        onTap: busy ? null : handleTap,
        onLongPress: (trashed || selectionMode)
            ? null
            : () => onToggleSelected?.call(true),
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
                _leading(context, completed),
                const SizedBox(width: ForgeSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        task.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          decoration: completed && !trashed
                              ? TextDecoration.lineThrough
                              : null,
                          color: completed && !trashed
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
                if (!selectionMode && !trashed)
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reads the current hardware keyboard modifiers and maps them to a
  /// [SelectionModifier] for a click made while multi-select is engaged.
  ///
  /// Forge uses an explicit selection mode (checkboxes visible), so a plain
  /// click toggles the row (touch-friendly and matches the checkbox), Shift
  /// extends a contiguous range from the anchor, and Ctrl/Cmd also toggles.
  /// The pure model still supports single-select for future non-modal lists.
  SelectionModifier _activeModifier() {
    final Set<LogicalKeyboardKey> pressed =
        HardwareKeyboard.instance.logicalKeysPressed;
    final bool shift =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    return shift ? SelectionModifier.range : SelectionModifier.toggle;
  }

  Widget _leading(BuildContext context, bool completed) {
    if (busy) {
      return const SizedBox(
        width: ForgeSizes.minimumInteractiveDimension,
        height: ForgeSizes.minimumInteractiveDimension,
        child: Padding(
          padding: EdgeInsets.all(ForgeSpacing.sm),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (selectionMode) {
      return SizedBox(
        width: ForgeSizes.minimumInteractiveDimension,
        height: ForgeSizes.minimumInteractiveDimension,
        child: Checkbox(
          value: selected,
          onChanged: (bool? next) => onToggleSelected?.call(next ?? !selected),
        ),
      );
    }
    if (trashed) {
      return const SizedBox(
        width: ForgeSizes.minimumInteractiveDimension,
        height: ForgeSizes.minimumInteractiveDimension,
        child: Icon(Icons.delete_outline),
      );
    }
    return SizedBox(
      width: ForgeSizes.minimumInteractiveDimension,
      height: ForgeSizes.minimumInteractiveDimension,
      child: Checkbox(
        value: completed,
        onChanged: (bool? next) => onToggleComplete(next ?? !completed),
      ),
    );
  }
}
