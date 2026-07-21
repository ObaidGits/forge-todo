import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_repository.dart';
import 'package:forge/features/goals/presentation/goal_labels.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/goals/presentation/widgets/goal_feedback_listener.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The accessible, adaptive goals list (R-GOAL-001, R-GOAL-007).
///
/// Goals are unlimited and never paid gated (R-GOAL-001). One screen renders
/// the Active, Archived and Trash views, switched by view chips. New goals are
/// created title-first and open straight into the detail screen. Archiving
/// preserves all history and links (R-GOAL-007) and offers immediate Undo.
/// Content is reconstructed from the local generation, so it is available
/// offline (R-GEN-001). This screen is deliberately a personal-goals surface:
/// it has no gantt, dependencies, or assignees (project-management non-goals).
final class GoalListScreen extends ConsumerWidget {
  const GoalListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<Goal>> goals = ref.watch(goalListProvider);
    final GoalViewKind view = ref.watch(goalViewProvider);

    ref.listen<GoalFeedback>(goalActionsProvider, (_, GoalFeedback next) {
      handleGoalFeedback(
        context,
        ref,
        next,
        dismiss: () => ref.read(goalActionsProvider.notifier).dismiss(),
      );
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.sm,
            ForgeSpacing.md,
            0,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: ref.watch(goalsDefaultAreaProvider) == null
                  ? null
                  : () => _createGoal(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.goalNew),
            ),
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        _ViewChips(view: view),
        const Divider(height: 1),
        Expanded(
          child: goals.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<Goal> list) => _buildList(context, ref, view, list),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    GoalViewKind view,
    List<Goal> list,
  ) {
    final AppLocalizations l10n = context.l10n;
    if (!ref.read(goalsConfiguredProvider)) {
      return _EmptyView(message: l10n.goalsUnavailable);
    }
    if (list.isEmpty) {
      return _EmptyView(message: _emptyMessage(l10n, view));
    }
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.goalsListLabel,
        child: ListView.separated(
          restorationId: 'content-goals-${view.name}',
          padding: const EdgeInsets.symmetric(
            horizontal: ForgeSpacing.xs,
            vertical: ForgeSpacing.xs,
          ),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: ForgeSpacing.xxs),
          itemBuilder: (BuildContext context, int index) {
            final Goal goal = list[index];
            return ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: _GoalTile(
                key: ValueKey<String>('goal-${goal.id.value}'),
                goal: goal,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _createGoal(BuildContext context, WidgetRef ref) async {
    final LifeAreaId? area = ref.read(goalsDefaultAreaProvider);
    if (area == null) {
      return;
    }
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _GoalTitlePromptDialog(),
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    final String? id = await ref
        .read(goalActionsProvider.notifier)
        .create(title: title.trim(), lifeAreaId: area);
    if (id != null && context.mounted) {
      unawaited(context.push('/goals/$id'));
    }
  }

  String _emptyMessage(AppLocalizations l10n, GoalViewKind view) =>
      switch (view) {
        GoalViewKind.active => l10n.goalsEmptyActive,
        GoalViewKind.archived => l10n.goalsEmptyArchived,
        GoalViewKind.trash => l10n.goalsEmptyTrash,
      };
}

final class _ViewChips extends ConsumerWidget {
  const _ViewChips({required this.view});

  final GoalViewKind view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
      child: Row(
        children: <Widget>[
          for (final (GoalViewKind kind, String label)
              in <(GoalViewKind, String)>[
                (GoalViewKind.active, l10n.goalViewActive),
                (GoalViewKind.archived, l10n.goalViewArchived),
                (GoalViewKind.trash, l10n.goalViewTrash),
              ])
            Padding(
              padding: const EdgeInsets.only(right: ForgeSpacing.xs),
              child: ChoiceChip(
                label: Text(label),
                selected: view == kind,
                onSelected: (_) =>
                    ref.read(goalViewProvider.notifier).set(kind),
              ),
            ),
        ],
      ),
    );
  }
}

final class _GoalTile extends ConsumerWidget {
  const _GoalTile({required this.goal, super.key});

  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final GoalActionsController actions = ref.read(
      goalActionsProvider.notifier,
    );
    final List<String> badges = <String>[
      GoalLabels.status(l10n, goal.status),
      if (goal.isArchived) l10n.goalArchivedBadge,
      if (goal.targetDate != null) l10n.goalTargetShort(goal.targetDate!),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(goal.title),
        subtitle: Text(badges.join(' · ')),
        onTap: goal.isDeleted
            ? null
            : () => context.push('/goals/${goal.id.value}'),
        trailing: goal.isDeleted
            ? null
            : IconButton(
                icon: Icon(
                  goal.isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                tooltip: goal.isArchived
                    ? l10n.goalUnarchive
                    : l10n.goalArchive,
                onPressed: () => unawaited(
                  actions.setArchived(
                    goal.id.value,
                    archived: !goal.isArchived,
                  ),
                ),
              ),
      ),
    );
  }
}

/// A small stateful dialog that owns its title controller so it is disposed
/// only after the dialog route is fully gone.
final class _GoalTitlePromptDialog extends StatefulWidget {
  const _GoalTitlePromptDialog();

  @override
  State<_GoalTitlePromptDialog> createState() => _GoalTitlePromptDialogState();
}

class _GoalTitlePromptDialogState extends State<_GoalTitlePromptDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.goalCreateTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l10n.goalCreateTitleLabel,
          hintText: l10n.goalCreateTitleHint,
        ),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.goalCreate),
        ),
      ],
    );
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
