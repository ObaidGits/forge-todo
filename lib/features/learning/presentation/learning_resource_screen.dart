import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/presentation/learning_labels.dart';
import 'package:forge/features/learning/presentation/learning_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The detail surface for one Learning Resource (R-LEARN-001..004).
///
/// It renders the resource's title, type, status, and transparent progress; its
/// ordered items with completion toggles; the read-only resume point; and a
/// study-session control that logs a durable session from an in-app start/stop
/// timer (R-LEARN-002, R-LEARN-003, R-LEARN-004). A single item opens its own
/// detail at `/learn/:resourceId/item/:itemId` (see `LearningItemScreen`), which
/// selects the item from this same resource projection.
final class LearningResourceScreen extends ConsumerWidget {
  const LearningResourceScreen({required this.resourceId, super.key});

  final String resourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<LearningResourceDetail?> detail = ref.watch(
      learningResourceDetailProvider(resourceId),
    );

    ref.listen<LearningFeedback>(learningActionsProvider, (
      _,
      LearningFeedback next,
    ) {
      if (next is LearningFeedbackError) {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorUnexpected)));
        ref.read(learningActionsProvider.notifier).dismiss();
      }
    });

    return detail.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (LearningResourceDetail? data) {
        if (data == null) {
          return ForgeEmptyState(
            icon: Icons.school_outlined,
            title: l10n.navLearn,
            body: l10n.learnResourceNotFound,
          );
        }
        return _Detail(resourceId: resourceId, detail: data);
      },
    );
  }
}

final class _Detail extends ConsumerWidget {
  const _Detail({required this.resourceId, required this.detail});

  final String resourceId;
  final LearningResourceDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String? runningResourceId = ref.watch(learningStudyTimerProvider);
    final bool studying = runningResourceId == resourceId;
    final String? resumeTitle = _resumeTitle(detail);

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-learn-$resourceId',
        padding: const EdgeInsets.all(ForgeSpacing.md),
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
                    detail.resource.title,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                Text(
                  <String>[
                    LearningLabels.resourceType(l10n, detail.resource.type),
                    LearningLabels.status(l10n, detail.resource.status),
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.md),
                _ProgressCard(progress: detail.progress),
                const SizedBox(height: ForgeSpacing.sm),
                _StudyControls(
                  resourceId: resourceId,
                  studying: studying,
                  resumeItemId: detail.resume.itemId,
                  sessionCount: detail.sessions.length,
                ),
                if (resumeTitle != null) ...<Widget>[
                  const SizedBox(height: ForgeSpacing.sm),
                  Semantics(
                    label: l10n.learnResumeAt(resumeTitle),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.play_circle_outline, size: 20),
                        const SizedBox(width: ForgeSpacing.xs),
                        Expanded(child: Text(l10n.learnResumeAt(resumeTitle))),
                      ],
                    ),
                  ),
                ] else ...<Widget>[
                  const SizedBox(height: ForgeSpacing.sm),
                  Text(
                    l10n.learnResumeComplete,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: ForgeSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.learnItemsLabel,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                if (detail.items.isEmpty)
                  Text(
                    l10n.learnNoItems,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final LearningItem item in detail.items)
                    _ItemTile(
                      key: ValueKey<String>('learn-item-${item.id}'),
                      resourceId: resourceId,
                      item: item,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _resumeTitle(LearningResourceDetail detail) {
    final String? resumeId = detail.resume.itemId;
    if (resumeId == null) {
      return null;
    }
    for (final LearningItem item in detail.items) {
      if (item.id == resumeId) {
        return item.title;
      }
    }
    return null;
  }
}

final class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final LearningProgress progress;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String value = LearningLabels.progress(l10n, progress);
    final String detail = progress.isStarted
        ? l10n.learnProgressCount(
            progress.completedCount,
            progress.eligibleCount,
          )
        : '';
    return Semantics(
      label: '${l10n.learnProgressLabel}: $value',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(ForgeSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.learnProgressLabel, style: theme.textTheme.labelLarge),
              const SizedBox(height: ForgeSpacing.xxs),
              Text(value, style: theme.textTheme.titleMedium),
              if (progress.isStarted) ...<Widget>[
                const SizedBox(height: ForgeSpacing.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.fraction.clamp(0.0, 1.0),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xxs),
                ExcludeSemantics(
                  child: Text(detail, style: theme.textTheme.bodySmall),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _StudyControls extends ConsumerWidget {
  const _StudyControls({
    required this.resourceId,
    required this.studying,
    required this.resumeItemId,
    required this.sessionCount,
  });

  final String resourceId;
  final bool studying;
  final String? resumeItemId;
  final int sessionCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final LearningActionsController actions = ref.read(
      learningActionsProvider.notifier,
    );
    return Row(
      children: <Widget>[
        if (studying)
          FilledButton.icon(
            onPressed: () => unawaited(
              actions.stopStudySession(resourceId, itemId: resumeItemId),
            ),
            icon: const Icon(Icons.stop),
            label: Text(l10n.learnStopStudy),
          )
        else
          FilledButton.tonalIcon(
            onPressed: () => actions.startStudySession(resourceId),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.learnStartStudy),
          ),
        const SizedBox(width: ForgeSpacing.md),
        Expanded(
          child: Text(
            studying
                ? l10n.learnStudyingNow
                : l10n.learnSessionCount(sessionCount),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

final class _ItemTile extends ConsumerWidget {
  const _ItemTile({required this.resourceId, required this.item, super.key});

  final String resourceId;
  final LearningItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final LearningActionsController actions = ref.read(
      learningActionsProvider.notifier,
    );
    // A section is a structural container, never an eligible progress leaf, so
    // it carries no completion control (R-LEARN-004).
    if (!item.isEligible) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xs),
        child: Semantics(
          header: true,
          child: Text(
            item.title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );
    }
    return Semantics(
      label: item.isComplete
          ? '${item.title}, ${l10n.learnItemDone}'
          : item.title,
      button: true,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: item.isComplete,
        title: Text(item.title),
        onChanged: (bool? checked) {
          if (checked ?? false) {
            unawaited(actions.completeItem(resourceId, item.id));
          } else {
            unawaited(actions.reopenItem(resourceId, item.id));
          }
        },
      ),
    );
  }
}
