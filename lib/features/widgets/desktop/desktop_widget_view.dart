import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/presentation/note_providers.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';

/// The compact desktop "sticky widget" (task §3).
///
/// A small card with **Today | Notes** tabs that reuses the app's existing
/// Riverpod providers directly — it is the same process/engine, so the
/// encrypted DatabaseRuntime writer lock is never contended and live data just
/// works. Header controls pin (always-on-top), lock (position), expand to the
/// full app, and hide to tray. The header is a drag handle for the frameless
/// window unless the position is locked.
final class DesktopWidgetView extends ConsumerStatefulWidget {
  const DesktopWidgetView({super.key});

  @override
  ConsumerState<DesktopWidgetView> createState() => _DesktopWidgetViewState();
}

class _DesktopWidgetViewState extends ConsumerState<DesktopWidgetView> {
  final FocusNode _addFocusNode = FocusNode();
  int _lastFocusTick = 0;

  @override
  void dispose() {
    _addFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DesktopWidgetState widgetState = ref.watch(
      desktopWidgetControllerProvider,
    );
    final DesktopWidgetPreferences prefs = widgetState.preferences;

    // React to a tray "Quick add" intent by focusing the add field.
    if (widgetState.focusAddTick != _lastFocusTick) {
      _lastFocusTick = widgetState.focusAddTick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _addFocusNode.requestFocus();
        }
      });
    }

    final ThemeData theme = Theme.of(context);
    final DesktopWidgetController controller = ref.read(
      desktopWidgetControllerProvider.notifier,
    );

    // Resolve the visible tabs from preferences.
    final bool showToday = prefs.tabs.showsToday;
    final bool showNotes = prefs.tabs.showsNotes;
    final WidgetTab activeTab = _clampTab(widgetState.activeTab, prefs.tabs);

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: <Widget>[
          _WidgetHeader(
            state: widgetState,
            onDragStart: () => unawaited(controller.startDragging()),
          ),
          if (prefs.alwaysOnTop && !widgetState.alwaysOnTopHonored)
            const _WaylandPinNotice(),
          if (showToday && showNotes)
            _TabBar(active: activeTab, onSelect: controller.selectTab),
          Expanded(
            child: switch (activeTab) {
              WidgetTab.today => _TodayTab(addFocusNode: _addFocusNode),
              WidgetTab.notes => _NotesTab(addFocusNode: _addFocusNode),
            },
          ),
        ],
      ),
    );
  }

  WidgetTab _clampTab(WidgetTab tab, WidgetTabs tabs) {
    if (tab == WidgetTab.today && !tabs.showsToday) {
      return WidgetTab.notes;
    }
    if (tab == WidgetTab.notes && !tabs.showsNotes) {
      return WidgetTab.today;
    }
    return tab;
  }
}

/// The draggable header with pin/lock/expand/close controls.
class _WidgetHeader extends ConsumerWidget {
  const _WidgetHeader({required this.state, required this.onDragStart});

  final DesktopWidgetState state;
  final VoidCallback onDragStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final DesktopWidgetController controller = ref.read(
      desktopWidgetControllerProvider.notifier,
    );
    final DesktopWidgetPreferences prefs = state.preferences;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: prefs.lockPosition ? null : (_) => onDragStart(),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: ForgeSpacing.sm),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: <Widget>[
            Icon(
              Icons.push_pin_outlined,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: ForgeSpacing.xs),
            Expanded(
              child: Text(
                'Forge',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _HeaderButton(
              tooltip: prefs.alwaysOnTop
                  ? 'Unpin (allow behind other windows)'
                  : 'Pin on top',
              icon: prefs.alwaysOnTop
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
              active: prefs.alwaysOnTop,
              onPressed: () => unawaited(
                controller.updatePreferences(
                  prefs.copyWith(alwaysOnTop: !prefs.alwaysOnTop),
                ),
              ),
            ),
            _HeaderButton(
              tooltip: prefs.lockPosition ? 'Unlock position' : 'Lock position',
              icon: prefs.lockPosition ? Icons.lock : Icons.lock_open,
              active: prefs.lockPosition,
              onPressed: () => unawaited(
                controller.updatePreferences(
                  prefs.copyWith(lockPosition: !prefs.lockPosition),
                ),
              ),
            ),
            _HeaderButton(
              tooltip: 'Open full app',
              icon: Icons.open_in_full,
              onPressed: () => unawaited(controller.enterFullMode()),
            ),
            _HeaderButton(
              tooltip: 'Hide widget',
              icon: Icons.close,
              onPressed: () =>
                  unawaited(ref.read(trayControllerProvider).hideWindow()),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      color: active ? theme.colorScheme.primary : null,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// A quiet, non-blocking notice that always-on-top could not be honored
/// (Wayland). It never crashes the widget; the toggle simply may not fully pin.
class _WaylandPinNotice extends StatelessWidget {
  const _WaylandPinNotice();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: ForgeSpacing.sm,
        vertical: ForgeSpacing.xxs,
      ),
      color: theme.colorScheme.secondaryContainer,
      child: Text(
        'Always-on-top isn\u2019t supported by this desktop (Wayland). '
        'The widget may not stay pinned.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.active, required this.onSelect});

  final WidgetTab active;
  final ValueChanged<WidgetTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _TabButton(
            label: 'Today',
            selected: active == WidgetTab.today,
            onTap: () => onSelect(WidgetTab.today),
          ),
        ),
        Expanded(
          child: _TabButton(
            label: 'Notes',
            selected: active == WidgetTab.notes,
            onTap: () => onSelect(WidgetTab.notes),
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Today tab: overdue + due-today tasks with inline completion, plus a
/// quick-add field. Reuses the Home Today controller and quick-capture
/// controller directly (same engine).
class _TodayTab extends ConsumerWidget {
  const _TodayTab({required this.addFocusNode});

  final FocusNode addFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<HomeState> home = ref.watch(homeControllerProvider);
    return Column(
      children: <Widget>[
        Expanded(
          child: home.when(
            loading: () =>
                const Center(child: CircularProgressIndicator.adaptive()),
            error: (Object e, StackTrace _) =>
                const _EmptyHint(text: 'Today is unavailable right now.'),
            data: (HomeState state) {
              if (!state.configured) {
                return const _EmptyHint(
                  text: 'Sign in to Forge to see today\u2019s tasks.',
                );
              }
              final TodayAgenda agenda = state.content.agenda;
              final List<TaskSummary> actionable = <TaskSummary>[
                ...agenda.overdue,
                ...agenda.dueToday,
              ];
              if (actionable.isEmpty && agenda.completedToday.isEmpty) {
                return const _EmptyHint(
                  text: 'Nothing due today. Add a task below.',
                );
              }
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
                children: <Widget>[
                  for (final TaskSummary task in actionable)
                    _TaskRow(task: task),
                  for (final TaskSummary task in agenda.completedToday)
                    _TaskRow(task: task),
                ],
              );
            },
          ),
        ),
        _QuickAddField(
          focusNode: addFocusNode,
          hint: 'Add a task\u2026',
          onSubmit: (String text) =>
              ref.read(quickCaptureControllerProvider.notifier).submit(text),
        ),
      ],
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool completed = task.isCompleted;
    return InkWell(
      onTap: () => unawaited(
        ref
            .read(homeControllerProvider.notifier)
            .setTaskComplete(taskId: task.id, complete: !completed),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ForgeSpacing.xs,
          vertical: ForgeSpacing.xxs,
        ),
        child: Row(
          children: <Widget>[
            Checkbox(
              value: completed,
              onChanged: (bool? next) => unawaited(
                ref
                    .read(homeControllerProvider.notifier)
                    .setTaskComplete(taskId: task.id, complete: next ?? false),
              ),
            ),
            Expanded(
              child: Text(
                task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  decoration: completed ? TextDecoration.lineThrough : null,
                  color: completed
                      ? theme.colorScheme.onSurfaceVariant
                      : task.isOverdue
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
            ),
            if (task.isOverdue && !completed)
              Padding(
                padding: const EdgeInsets.only(left: ForgeSpacing.xxs),
                child: Icon(
                  Icons.schedule,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Notes tab: recent/pinned notes with a quick-jot field that creates a
/// note. Reuses the notes list + actions providers directly.
class _NotesTab extends ConsumerWidget {
  const _NotesTab({required this.addFocusNode});

  final FocusNode addFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Note>> notes = ref.watch(noteListProvider);
    return Column(
      children: <Widget>[
        Expanded(
          child: notes.when(
            loading: () =>
                const Center(child: CircularProgressIndicator.adaptive()),
            error: (Object e, StackTrace _) =>
                const _EmptyHint(text: 'Notes are unavailable right now.'),
            data: (List<Note> all) {
              if (all.isEmpty) {
                return const _EmptyHint(
                  text: 'No notes yet. Jot one down below.',
                );
              }
              // Pinned first, then most-recently updated; cap for the compact
              // surface.
              final List<Note> sorted = <Note>[...all]
                ..sort((Note a, Note b) {
                  if (a.pinned != b.pinned) {
                    return a.pinned ? -1 : 1;
                  }
                  return b.updatedAtUtc.compareTo(a.updatedAtUtc);
                });
              final List<Note> shown = sorted.take(20).toList();
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
                children: <Widget>[
                  for (final Note note in shown) _NoteRow(note: note),
                ],
              );
            },
          ),
        ),
        _QuickAddField(
          focusNode: addFocusNode,
          hint: 'Jot a note\u2026',
          onSubmit: (String text) async {
            final String? id = await ref
                .read(noteActionsProvider.notifier)
                .create(title: text);
            return id != null;
          },
        ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ForgeSpacing.sm,
        vertical: ForgeSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            note.pinned ? Icons.push_pin : Icons.sticky_note_2_outlined,
            size: 16,
            color: note.pinned
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: ForgeSpacing.xs),
          Expanded(
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact submit-on-enter text field shared by both tabs. Clears on a
/// successful submit and retains focus for rapid entry.
class _QuickAddField extends StatefulWidget {
  const _QuickAddField({
    required this.focusNode,
    required this.hint,
    required this.onSubmit,
  });

  final FocusNode focusNode;
  final String hint;
  final Future<bool> Function(String text) onSubmit;

  @override
  State<_QuickAddField> createState() => _QuickAddFieldState();
}

class _QuickAddFieldState extends State<_QuickAddField> {
  final TextEditingController _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty || _submitting) {
      return;
    }
    setState(() => _submitting = true);
    final bool ok = await widget.onSubmit(text);
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    if (ok) {
      _controller.clear();
      widget.focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(ForgeSpacing.xs),
      child: TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_submit()),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: ForgeSpacing.sm,
            vertical: ForgeSpacing.xs,
          ),
          suffixIcon: IconButton(
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            tooltip: 'Add',
            onPressed: _submitting ? null : () => unawaited(_submit()),
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
