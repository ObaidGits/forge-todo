import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/presentation/task_labels.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The always-visible filter and view controls (FilterBar, R-TASK-002,
/// R-TASK-008). Views render as a horizontally scrollable chip group; the
/// active filter summary is always visible next to a button that opens the
/// composable filter sheet.
final class TaskFilterBar extends ConsumerWidget {
  const TaskFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final TaskListView view = ref.watch(taskViewProvider);
    final int activeFilters = ref.watch(
      taskFilterProvider.select((f) => f.activeCount),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.xs),
          child: Row(
            children: <Widget>[
              for (final TaskListView v in TaskListView.values)
                Padding(
                  padding: const EdgeInsets.only(right: ForgeSpacing.xs),
                  child: ChoiceChip(
                    label: Text(TaskLabels.view(l10n, v.wire)),
                    selected: view == v,
                    onSelected: (_) =>
                        ref.read(taskViewProvider.notifier).set(v),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  activeFilters == 0
                      ? l10n.taskFiltersNone
                      : l10n.taskFiltersActive(activeFilters),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (activeFilters > 0)
                TextButton(
                  onPressed: () =>
                      ref.read(taskFilterProvider.notifier).clear(),
                  child: Text(l10n.taskFiltersClear),
                ),
              TextButton.icon(
                onPressed: () => _openFilterSheet(context, ref),
                icon: const Icon(Icons.filter_list),
                label: Text(l10n.taskFilters),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openFilterSheet(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => const _TaskFilterSheet(),
    );
  }
}

final class _TaskFilterSheet extends ConsumerWidget {
  const _TaskFilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final filter = ref.watch(taskFilterProvider);
    final notifier = ref.read(taskFilterProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: ForgeSpacing.lg,
          right: ForgeSpacing.lg,
          top: ForgeSpacing.md,
          bottom: MediaQuery.viewInsetsOf(context).bottom + ForgeSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  l10n.taskFilters,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: ForgeSpacing.md),
              TextField(
                decoration: InputDecoration(
                  labelText: l10n.taskFilterText,
                  prefixIcon: const Icon(Icons.search),
                ),
                controller: TextEditingController(text: filter.text ?? '')
                  ..selection = TextSelection.collapsed(
                    offset: (filter.text ?? '').length,
                  ),
                onSubmitted: notifier.setText,
              ),
              const SizedBox(height: ForgeSpacing.md),
              Semantics(
                header: true,
                child: Text(
                  l10n.taskFilterPriority,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Wrap(
                spacing: ForgeSpacing.xs,
                children: <Widget>[
                  for (final String wire in const <String>[
                    'urgent',
                    'high',
                    'medium',
                    'low',
                    'none',
                  ])
                    FilterChip(
                      label: Text(TaskLabels.priority(l10n, wire)),
                      selected: filter.priorityWires.contains(wire),
                      onSelected: (_) => notifier.togglePriority(wire),
                    ),
                ],
              ),
              const SizedBox(height: ForgeSpacing.md),
              Semantics(
                header: true,
                child: Text(
                  l10n.taskFilterStatus,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Wrap(
                spacing: ForgeSpacing.xs,
                children: <Widget>[
                  for (final String wire in const <String>[
                    'open',
                    'in_progress',
                  ])
                    FilterChip(
                      label: Text(TaskLabels.status(l10n, wire)),
                      selected: filter.statusWires.contains(wire),
                      onSelected: (_) => notifier.toggleStatus(wire),
                    ),
                ],
              ),
              const SizedBox(height: ForgeSpacing.md),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.taskFilterRecurring),
                value: filter.hasRecurrence ?? false,
                onChanged: (bool value) =>
                    notifier.setRecurrence(value ? true : null),
              ),
              const SizedBox(height: ForgeSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  TextButton(
                    onPressed: () {
                      notifier.clear();
                      Navigator.of(context).pop();
                    },
                    child: Text(l10n.taskFiltersClear),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.actionClose),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
