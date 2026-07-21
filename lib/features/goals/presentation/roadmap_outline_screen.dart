import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/goals/presentation/goal_labels.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/goals/presentation/widgets/goal_feedback_listener.dart';
import 'package:forge/features/goals/presentation/widgets/goal_progress_card.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible, adaptive roadmap outline (R-GOAL-003, R-GOAL-004,
/// R-GOAL-005).
///
/// Renders the goal's single roadmap as ordered sections → topics → checklist
/// items. Each section shows a presentation-only aggregation of its eligible
/// descendant topic weights (R-GOAL-004); the roadmap total is shown once at
/// the top with its transparent formula. Reordering is keyboard-first: every
/// section and topic exposes explicit Move up / Move down controls with
/// announcements, never drag-only, plus a per-collection Rebalance affordance
/// (R-GOAL-005; ux-design §4). This is deliberately not a project-management
/// tool: no gantt, no dependencies, no assignees.
final class RoadmapOutlineScreen extends ConsumerWidget {
  const RoadmapOutlineScreen({required this.goalId, super.key});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<RoadmapOutline?> outline = ref.watch(
      roadmapOutlineProvider(goalId),
    );

    ref.listen<GoalFeedback>(roadmapActionsProvider, (_, GoalFeedback next) {
      handleGoalFeedback(
        context,
        ref,
        next,
        dismiss: () => ref.read(roadmapActionsProvider.notifier).dismiss(),
      );
    });

    return outline.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (RoadmapOutline? data) {
        if (data == null) {
          return _NotFound(message: l10n.goalDetailNotFound);
        }
        if (!data.hasRoadmap) {
          return _NoRoadmap(goalId: goalId, goalTitle: data.goal.title);
        }
        return _OutlineBody(goalId: goalId, outline: data);
      },
    );
  }
}

final class _OutlineBody extends ConsumerWidget {
  const _OutlineBody({required this.goalId, required this.outline});

  final String goalId;
  final RoadmapOutline outline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final RoadmapActionsController actions = ref.read(
      roadmapActionsProvider.notifier,
    );
    final List<RoadmapSection> orderedSections = outline.sections
        .map((RoadmapSectionView s) => s.section)
        .toList(growable: false);

    return ListView(
      restorationId: 'content-roadmap-outline',
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
                child: Text(
                  outline.roadmap!.title,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: ForgeSpacing.md),
              GoalProgressCard(progress: outline.progress),
              const SizedBox(height: ForgeSpacing.md),
              Wrap(
                spacing: ForgeSpacing.xs,
                runSpacing: ForgeSpacing.xs,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => _addSection(context, ref),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.goalSectionAdd),
                  ),
                  if (orderedSections.length > 1)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        actions.rebalanceSections(
                          goalId,
                          outline.roadmap!.id.value,
                        ),
                      ),
                      icon: const Icon(Icons.balance),
                      label: Text(l10n.goalRebalanceSections),
                    ),
                ],
              ),
              const SizedBox(height: ForgeSpacing.md),
              if (outline.sections.isEmpty)
                Text(l10n.goalSectionsEmpty, style: theme.textTheme.bodyMedium)
              else
                FocusTraversalGroup(
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < outline.sections.length; i += 1)
                        _SectionCard(
                          key: ValueKey<String>(
                            'section-${outline.sections[i].section.id.value}',
                          ),
                          goalId: goalId,
                          view: outline.sections[i],
                          index: i,
                          orderedSections: orderedSections,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addSection(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? title = await _promptText(
      context,
      title: l10n.goalSectionAdd,
      label: l10n.goalSectionTitleLabel,
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(roadmapActionsProvider.notifier)
        .addSection(goalId, outline.roadmap!.id.value, title: title.trim());
  }
}

final class _SectionCard extends ConsumerWidget {
  const _SectionCard({
    required this.goalId,
    required this.view,
    required this.index,
    required this.orderedSections,
    super.key,
  });

  final String goalId;
  final RoadmapSectionView view;
  final int index;
  final List<RoadmapSection> orderedSections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final RoadmapActionsController actions = ref.read(
      roadmapActionsProvider.notifier,
    );
    final List<RoadmapTopic> orderedTopics = view.topics
        .map((RoadmapTopicView t) => t.topic)
        .toList(growable: false);

    return Card(
      margin: const EdgeInsets.only(bottom: ForgeSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      view.section.title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                SectionAggregationChip(aggregation: view.aggregation),
                _ReorderControls(
                  label: view.section.title,
                  canMoveUp: index > 0,
                  canMoveDown: index < orderedSections.length - 1,
                  onMoveUp: () => unawaited(
                    actions.moveSectionUp(goalId, orderedSections, index),
                  ),
                  onMoveDown: () => unawaited(
                    actions.moveSectionDown(goalId, orderedSections, index),
                  ),
                ),
              ],
            ),
            const SizedBox(height: ForgeSpacing.xs),
            if (view.topics.isEmpty)
              Text(l10n.goalTopicsEmpty, style: theme.textTheme.bodySmall)
            else
              for (int i = 0; i < view.topics.length; i += 1)
                _TopicTile(
                  key: ValueKey<String>(
                    'topic-${view.topics[i].topic.id.value}',
                  ),
                  goalId: goalId,
                  view: view.topics[i],
                  index: i,
                  orderedTopics: orderedTopics,
                ),
            const SizedBox(height: ForgeSpacing.xs),
            Wrap(
              spacing: ForgeSpacing.xs,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => _addTopic(context, ref),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.goalTopicAdd),
                ),
                if (view.topics.length > 1)
                  TextButton.icon(
                    onPressed: () => unawaited(
                      actions.rebalanceTopics(goalId, view.section.id.value),
                    ),
                    icon: const Icon(Icons.balance),
                    label: Text(l10n.goalRebalanceTopics),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addTopic(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? title = await _promptText(
      context,
      title: l10n.goalTopicAdd,
      label: l10n.goalTopicTitleLabel,
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(roadmapActionsProvider.notifier)
        .addTopic(goalId, view.section.id.value, title: title.trim());
  }
}

final class _TopicTile extends ConsumerWidget {
  const _TopicTile({
    required this.goalId,
    required this.view,
    required this.index,
    required this.orderedTopics,
    super.key,
  });

  final String goalId;
  final RoadmapTopicView view;
  final int index;
  final List<RoadmapTopic> orderedTopics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final RoadmapActionsController actions = ref.read(
      roadmapActionsProvider.notifier,
    );
    final RoadmapTopic topic = view.topic;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Semantics(
                label: l10n.goalTopicToggle(topic.title),
                child: Checkbox(
                  value: topic.isCompleted,
                  onChanged: (bool? value) => unawaited(
                    actions.setTopicStatus(
                      goalId,
                      topic.id.value,
                      (value ?? false)
                          ? RoadmapTopicStatus.completed
                          : RoadmapTopicStatus.open,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(topic.title, style: theme.textTheme.bodyLarge),
                    Text(
                      l10n.goalTopicMeta(
                        GoalLabels.topicStatus(l10n, topic.status),
                        _weightText(l10n, topic.weight),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _ReorderControls(
                label: topic.title,
                canMoveUp: index > 0,
                canMoveDown: index < orderedTopics.length - 1,
                onMoveUp: () => unawaited(
                  actions.moveTopicUp(goalId, orderedTopics, index),
                ),
                onMoveDown: () => unawaited(
                  actions.moveTopicDown(goalId, orderedTopics, index),
                ),
              ),
            ],
          ),
          if (view.checklist.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: ForgeSpacing.xl),
              child: Column(
                children: <Widget>[
                  for (final ChecklistItem item in view.checklist)
                    _ChecklistTile(goalId: goalId, item: item),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: ForgeSpacing.xl),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _addChecklistItem(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.goalChecklistAdd),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _weightText(AppLocalizations l10n, num? weight) {
    if (weight == null) {
      return l10n.goalTopicWeightDefault;
    }
    final String value = weight == weight.roundToDouble()
        ? weight.toInt().toString()
        : weight.toStringAsFixed(2);
    return l10n.goalTopicWeight(value);
  }

  Future<void> _addChecklistItem(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? text = await _promptText(
      context,
      title: l10n.goalChecklistAdd,
      label: l10n.goalChecklistTextLabel,
    );
    if (text == null || text.trim().isEmpty) {
      return;
    }
    await ref
        .read(roadmapActionsProvider.notifier)
        .addChecklistItem(goalId, view.topic.id.value, text: text.trim());
  }
}

final class _ChecklistTile extends ConsumerWidget {
  const _ChecklistTile({required this.goalId, required this.item});

  final String goalId;
  final ChecklistItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RoadmapActionsController actions = ref.read(
      roadmapActionsProvider.notifier,
    );
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: item.isChecked,
      onChanged: (bool? value) => unawaited(
        actions.setChecklistChecked(
          goalId,
          item.id.value,
          checked: value ?? false,
        ),
      ),
      title: Text(item.text),
    );
  }
}

/// The explicit keyboard/pointer reorder controls that replace drag
/// (R-GOAL-005; ux-design §4). Each button has a descriptive tooltip/semantic
/// label naming the item so a screen-reader user knows what will move.
final class _ReorderControls extends StatelessWidget {
  const _ReorderControls({
    required this.label,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final String label;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.arrow_upward),
          tooltip: l10n.goalMoveUp(label),
          onPressed: canMoveUp ? onMoveUp : null,
        ),
        IconButton(
          icon: const Icon(Icons.arrow_downward),
          tooltip: l10n.goalMoveDown(label),
          onPressed: canMoveDown ? onMoveDown : null,
        ),
      ],
    );
  }
}

final class _NoRoadmap extends ConsumerWidget {
  const _NoRoadmap({required this.goalId, required this.goalTitle});

  final String goalId;
  final String goalTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.goalRoadmapNoneBody,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: ForgeSpacing.md),
            FilledButton.icon(
              onPressed: () => _createRoadmap(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.goalRoadmapCreate),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createRoadmap(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? title = await _promptText(
      context,
      title: l10n.goalRoadmapCreate,
      label: l10n.goalRoadmapTitleLabel,
      initial: goalTitle,
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(roadmapActionsProvider.notifier)
        .createRoadmap(goalId, title: title.trim());
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
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}

/// Shared single-field prompt used to add sections, topics, checklist items,
/// and the roadmap itself. Keeps its controller alive until the route is gone.
Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        _TextPromptDialog(title: title, label: label, initial: initial),
  );
}

final class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    this.initial,
  });

  final String title;
  final String label;
  final String? initial;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.goalDialogAdd),
        ),
      ],
    );
  }
}
