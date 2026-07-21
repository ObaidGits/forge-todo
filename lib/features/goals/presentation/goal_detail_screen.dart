import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_motion.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/goals/presentation/goal_labels.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/goals/presentation/widgets/goal_feedback_listener.dart';
import 'package:forge/features/goals/presentation/widgets/goal_progress_card.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The goal detail view (R-GOAL-002, R-GOAL-004, R-GOAL-006, R-GOAL-007).
///
/// Shows the goal's outcome, Life Area, status, target date, tags, milestones,
/// and the transparent derived-or-manual progress surface (formula + eligible
/// count + total weight, R-GOAL-004). Milestones can be completed with a
/// subtle, dismissible, reduced-motion-respecting celebration (R-GOAL-006).
/// Archiving preserves history and links (R-GOAL-007). It links to the goal's
/// single roadmap. There is deliberately no gantt/dependency/assignee surface.
final class GoalDetailScreen extends ConsumerStatefulWidget {
  const GoalDetailScreen({required this.goalId, super.key});

  final String goalId;

  @override
  ConsumerState<GoalDetailScreen> createState() => _GoalDetailScreenState();
}

class _GoalDetailScreenState extends ConsumerState<GoalDetailScreen> {
  String? _celebration;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<GoalDetailView?> detail = ref.watch(
      goalDetailProvider(widget.goalId),
    );

    ref.listen<GoalFeedback>(goalActionsProvider, (_, GoalFeedback next) {
      if (next is GoalFeedbackCelebrate) {
        setState(() => _celebration = next.milestoneTitle);
      }
      handleGoalFeedback(
        context,
        ref,
        next,
        dismiss: () => ref.read(goalActionsProvider.notifier).dismiss(),
      );
    });

    return detail.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (GoalDetailView? view) {
        if (view == null) {
          return _NotFound(message: l10n.goalDetailNotFound);
        }
        return _DetailBody(
          view: view,
          celebration: _celebration,
          onDismissCelebration: () => setState(() => _celebration = null),
        );
      },
    );
  }
}

final class _DetailBody extends ConsumerWidget {
  const _DetailBody({
    required this.view,
    required this.celebration,
    required this.onDismissCelebration,
  });

  final GoalDetailView view;
  final String? celebration;
  final VoidCallback onDismissCelebration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final Goal goal = view.goal;

    return ListView(
      restorationId: 'content-goal-detail',
      padding: const EdgeInsets.all(ForgeSpacing.lg),
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ForgeSizes.readableContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (celebration != null)
                _MilestoneCelebration(
                  title: celebration!,
                  onDismiss: onDismissCelebration,
                ),
              Semantics(
                header: true,
                child: Text(goal.title, style: theme.textTheme.headlineSmall),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Wrap(
                spacing: ForgeSpacing.xs,
                runSpacing: ForgeSpacing.xxs,
                children: <Widget>[
                  _Chip(label: GoalLabels.status(l10n, goal.status)),
                  if (goal.isArchived) _Chip(label: l10n.goalArchivedBadge),
                  for (final String tag in view.tagIds) _Chip(label: tag),
                ],
              ),
              if (goal.outcomeMd.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: ForgeSpacing.md),
                Text(l10n.goalOutcomeLabel, style: theme.textTheme.labelLarge),
                const SizedBox(height: ForgeSpacing.xxs),
                Text(goal.outcomeMd, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: ForgeSpacing.md),
              GoalProgressCard(progress: view.progress),
              const SizedBox(height: ForgeSpacing.md),
              _fields(context, l10n, _areaName(ref, l10n)),
              const SizedBox(height: ForgeSpacing.md),
              _actions(context, ref, l10n),
              const SizedBox(height: ForgeSpacing.lg),
              _roadmapLink(context, l10n),
              const SizedBox(height: ForgeSpacing.lg),
              _milestones(context, ref, l10n, theme),
            ],
          ),
        ),
      ],
    );
  }

  String _areaName(WidgetRef ref, AppLocalizations l10n) {
    final List<GoalAreaOption> options = ref.watch(goalsAreaOptionsProvider);
    for (final GoalAreaOption option in options) {
      if (option.id == view.goal.lifeAreaId) {
        return option.name;
      }
    }
    return l10n.goalAreaUnknown;
  }

  Widget _fields(BuildContext context, AppLocalizations l10n, String areaName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _field(context, l10n.goalDetailArea, areaName),
        _field(
          context,
          l10n.goalDetailStatus,
          GoalLabels.status(l10n, view.goal.status),
        ),
        _field(
          context,
          l10n.goalDetailTargetDate,
          view.goal.targetDate ?? l10n.goalNoTargetDate,
        ),
        _field(
          context,
          l10n.goalDetailProgressMode,
          GoalLabels.progressMode(l10n, view.goal.progressMode),
        ),
      ],
    );
  }

  Widget _field(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 132,
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

  Widget _actions(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final GoalActionsController actions = ref.read(
      goalActionsProvider.notifier,
    );
    final Goal goal = view.goal;
    return Wrap(
      spacing: ForgeSpacing.xs,
      runSpacing: ForgeSpacing.xs,
      children: <Widget>[
        if (goal.status != GoalStatus.achieved)
          FilledButton.icon(
            onPressed: () => unawaited(
              actions.setStatus(goal.id.value, GoalStatus.achieved),
            ),
            icon: const Icon(Icons.emoji_events_outlined),
            label: Text(l10n.goalMarkAchieved),
          ),
        if (goal.status != GoalStatus.active)
          OutlinedButton.icon(
            onPressed: () =>
                unawaited(actions.setStatus(goal.id.value, GoalStatus.active)),
            icon: const Icon(Icons.play_circle_outline),
            label: Text(l10n.goalMarkActive),
          ),
        if (goal.status == GoalStatus.active)
          OutlinedButton.icon(
            onPressed: () =>
                unawaited(actions.setStatus(goal.id.value, GoalStatus.onHold)),
            icon: const Icon(Icons.pause_circle_outline),
            label: Text(l10n.goalMarkOnHold),
          ),
        OutlinedButton.icon(
          onPressed: () => unawaited(
            actions.setArchived(goal.id.value, archived: !goal.isArchived),
          ),
          icon: Icon(
            goal.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
          ),
          label: Text(goal.isArchived ? l10n.goalUnarchive : l10n.goalArchive),
        ),
      ],
    );
  }

  Widget _roadmapLink(BuildContext context, AppLocalizations l10n) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.route_outlined),
        title: Text(l10n.goalRoadmapTitle),
        subtitle: Text(
          view.hasRoadmap ? l10n.goalRoadmapOpen : l10n.goalRoadmapNone,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/goals/${view.goal.id.value}/roadmap'),
      ),
    );
  }

  Widget _milestones(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final GoalActionsController actions = ref.read(
      goalActionsProvider.notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  l10n.goalMilestonesHeading(
                    view.completedMilestones,
                    view.milestones.length,
                  ),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => _addMilestone(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.goalMilestoneAdd),
            ),
          ],
        ),
        if (view.milestones.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xs),
            child: Text(
              l10n.goalMilestonesEmpty,
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          FocusTraversalGroup(
            child: Column(
              children: <Widget>[
                for (final Milestone milestone in view.milestones)
                  _MilestoneTile(
                    key: ValueKey<String>('milestone-${milestone.id.value}'),
                    milestone: milestone,
                    onToggle: (bool complete) {
                      if (complete) {
                        unawaited(
                          actions.completeMilestone(
                            view.goal.id.value,
                            milestone.id.value,
                            milestone.title,
                          ),
                        );
                      } else {
                        unawaited(
                          actions.uncompleteMilestone(
                            view.goal.id.value,
                            milestone.id.value,
                          ),
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _addMilestone(BuildContext context, WidgetRef ref) async {
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _MilestonePromptDialog(),
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(goalActionsProvider.notifier)
        .addMilestone(view.goal.id.value, title: title.trim());
  }
}

/// A subtle, dismissible milestone celebration (R-GOAL-006). It respects
/// reduced-motion: when animations are disabled it appears immediately with no
/// transition; otherwise it uses a brief, compositor-friendly fade. It is never
/// confetti or looping decoration (ux-design §10).
final class _MilestoneCelebration extends StatelessWidget {
  const _MilestoneCelebration({required this.title, required this.onDismiss});

  final String title;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final Widget banner = Container(
      margin: const EdgeInsets.only(bottom: ForgeSpacing.md),
      padding: const EdgeInsets.all(ForgeSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(ForgeRadii.card),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.celebration_outlined,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: ForgeSpacing.xs),
          Expanded(
            child: Text(
              l10n.goalMilestoneCelebration(title),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.actionClose,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
    return Semantics(
      key: const ValueKey<String>('goal-milestone-celebration'),
      liveRegion: true,
      child: ForgeAnimatedSwitcher(
        duration: ForgeDurations.content,
        child: banner,
      ),
    );
  }
}

final class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile({
    required this.milestone,
    required this.onToggle,
    super.key,
  });

  final Milestone milestone;
  final void Function(bool complete) onToggle;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: milestone.isCompleted,
      onChanged: (bool? value) => onToggle(value ?? false),
      title: Text(milestone.title),
      subtitle: milestone.targetDate == null
          ? null
          : Text(l10n.goalTargetShort(milestone.targetDate!)),
      secondary: milestone.isCompleted
          ? Tooltip(
              message: l10n.goalMilestoneCompleted,
              child: const Icon(Icons.check_circle_outline),
            )
          : null,
    );
  }
}

final class _MilestonePromptDialog extends StatefulWidget {
  const _MilestonePromptDialog();

  @override
  State<_MilestonePromptDialog> createState() => _MilestonePromptDialogState();
}

class _MilestonePromptDialogState extends State<_MilestonePromptDialog> {
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
      title: Text(l10n.goalMilestoneAdd),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l10n.goalMilestoneTitleLabel,
          hintText: l10n.goalMilestoneTitleHint,
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
          child: Text(l10n.goalMilestoneAddConfirm),
        ),
      ],
    );
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
              onPressed: () => context.go('/goals'),
              child: Text(context.l10n.navGoals),
            ),
          ],
        ),
      ),
    );
  }
}
