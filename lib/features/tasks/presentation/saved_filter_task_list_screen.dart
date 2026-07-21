import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';
import 'package:forge/features/search/presentation/search_providers.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/presentation/task_list_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Renders the task list narrowed by a recalled saved filter (`/tasks/filter/
/// :filterId`) (R-SEARCH-002, R-TASK-008).
///
/// A saved filter is a durable, recallable query the user named; it is resolved
/// by id from the already-wired saved-filters store ([savedFiltersProvider]).
/// Its stored query maps onto the task list's free-text title filter, so the
/// list opens showing the tasks that match. When the id no longer resolves to a
/// saved filter the surface shows a calm, accessible "filter not found" state
/// rather than crashing or silently showing an unfiltered list.
final class SavedFilterTaskListScreen extends ConsumerWidget {
  const SavedFilterTaskListScreen({required this.filterId, super.key});

  final String filterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<SavedSearchFilter>> filters = ref.watch(
      savedFiltersProvider,
    );

    return filters.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => _notFound(l10n),
      data: (List<SavedSearchFilter> list) {
        final SavedSearchFilter? match = _resolve(list);
        if (match == null) {
          return _notFound(l10n);
        }
        // The saved query recalls onto the title filter; an empty query yields
        // the full list (no active facet), which is a valid recalled view.
        final TaskFilter filter = TaskFilter(text: match.query);
        return TaskListScreen(
          key: ValueKey<String>('saved-filter-$filterId'),
          initialView: TaskListView.today,
          initialFilter: filter,
        );
      },
    );
  }

  SavedSearchFilter? _resolve(List<SavedSearchFilter> list) {
    for (final SavedSearchFilter filter in list) {
      if (filter.id == filterId) {
        return filter;
      }
    }
    return null;
  }

  Widget _notFound(AppLocalizations l10n) => ForgeEmptyState(
    icon: Icons.filter_alt_off_outlined,
    title: l10n.tasksSavedFilterNotFoundTitle,
    body: l10n.tasksSavedFilterNotFoundBody,
  );
}
