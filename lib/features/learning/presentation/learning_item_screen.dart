import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/presentation/learning_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The detail surface for one item inside a Learning Resource (R-LEARN-001,
/// R-LEARN-002, R-LEARN-004).
///
/// It renders the item's title, type, and completion status; a mark-complete /
/// reopen control for eligible leaves reusing the learning command service
/// (R-LEARN-004); and the study sessions that named this item (R-LEARN-002,
/// R-LEARN-003). The item and its sessions are resolved from the already-wired
/// resource detail projection ([learningResourceDetailProvider]) — items are
/// selected by id from the resource's ordered items, so no additional read is
/// required. Content is reconstructed from the local generation, so it is
/// available offline (R-GEN-001).
final class LearningItemScreen extends ConsumerWidget {
  const LearningItemScreen({
    required this.resourceId,
    required this.itemId,
    super.key,
  });

  final String resourceId;
  final String itemId;

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
      error: (Object error, StackTrace _) =>
          Center(child: Text(l10n.errorUnexpected)),
      data: (LearningResourceDetail? data) {
        final LearningItem? item = _findItem(data);
        if (data == null || item == null) {
          return ForgeEmptyState(
            icon: Icons.school_outlined,
            title: l10n.navLearn,
            body: l10n.learnItemNotFound,
          );
        }
        final List<StudySession> sessions = data.sessions
            .where((StudySession s) => s.itemId == itemId)
            .toList(growable: false);
        return _Detail(
          resourceId: resourceId,
          resourceTitle: data.resource.title,
          item: item,
          sessions: sessions,
        );
      },
    );
  }

  LearningItem? _findItem(LearningResourceDetail? data) {
    if (data == null) {
      return null;
    }
    for (final LearningItem item in data.items) {
      if (item.id == itemId) {
        return item;
      }
    }
    return null;
  }
}

final class _Detail extends ConsumerWidget {
  const _Detail({
    required this.resourceId,
    required this.resourceTitle,
    required this.item,
    required this.sessions,
  });

  final String resourceId;
  final String resourceTitle;
  final LearningItem item;
  final List<StudySession> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String status = item.isComplete
        ? l10n.learnItemStatusComplete
        : l10n.learnItemStatusIncomplete;

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-learn-item-${item.id}',
        padding: const EdgeInsets.all(ForgeSpacing.md),
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ForgeSizes.readableContentMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  resourceTitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xxs),
                Semantics(
                  header: true,
                  child: Text(item.title, style: theme.textTheme.headlineSmall),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                // Type and completion status are text, never colour-only
                // (NFR-A11Y-003).
                Row(
                  children: <Widget>[
                    Icon(
                      item.isComplete
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      size: 20,
                    ),
                    const SizedBox(width: ForgeSpacing.xs),
                    Text(
                      '${_typeLabel(l10n, item.type)} · $status',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (item.isEligible) ...<Widget>[
                  const SizedBox(height: ForgeSpacing.md),
                  _CompletionButton(resourceId: resourceId, item: item),
                ],
                const SizedBox(height: ForgeSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.learnSessionsLabel,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                if (sessions.isEmpty)
                  Text(
                    l10n.learnItemNoSessions,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final StudySession session in sessions)
                    _SessionRow(
                      key: ValueKey<String>('learn-session-${session.id}'),
                      session: session,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(AppLocalizations l10n, LearningItemType type) {
    return switch (type) {
      LearningItemType.section => l10n.learnItemTypeSection,
      LearningItemType.lesson => l10n.learnItemTypeLesson,
      LearningItemType.video => l10n.learnItemTypeVideo,
      LearningItemType.chapter => l10n.learnItemTypeChapter,
      LearningItemType.article => l10n.learnItemTypeArticle,
      LearningItemType.exercise => l10n.learnItemTypeExercise,
      LearningItemType.other => l10n.learnItemTypeOther,
    };
  }
}

final class _CompletionButton extends ConsumerWidget {
  const _CompletionButton({required this.resourceId, required this.item});

  final String resourceId;
  final LearningItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final LearningActionsController actions = ref.read(
      learningActionsProvider.notifier,
    );
    final ButtonStyle style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(
        ForgeSizes.minimumInteractiveDimension,
      ),
    );
    if (item.isComplete) {
      return OutlinedButton.icon(
        key: const ValueKey<String>('learn-item-reopen'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(
            ForgeSizes.minimumInteractiveDimension,
          ),
        ),
        onPressed: () => unawaited(actions.reopenItem(resourceId, item.id)),
        icon: const Icon(Icons.undo),
        label: Text(l10n.learnItemReopenAction),
      );
    }
    return FilledButton.icon(
      key: const ValueKey<String>('learn-item-complete'),
      style: style,
      onPressed: () => unawaited(actions.completeItem(resourceId, item.id)),
      icon: const Icon(Icons.check),
      label: Text(l10n.learnItemComplete),
    );
  }
}

final class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, super.key});

  final StudySession session;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String date = _formatDate(session.startedAtUtc);
    final String duration = _formatDuration(session.durationSec);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
        child: Row(
          children: <Widget>[
            const Icon(Icons.timelapse, size: 20),
            const SizedBox(width: ForgeSpacing.xs),
            Expanded(
              child: Text(
                l10n.learnItemStudiedLine(date, duration),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(int totalSec) {
  final int hours = totalSec ~/ 3600;
  final int minutes = (totalSec % 3600) ~/ 60;
  final int seconds = totalSec % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) {
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}

String _formatDate(int utcMicros) {
  final DateTime dt = DateTime.fromMicrosecondsSinceEpoch(
    utcMicros,
    isUtc: true,
  );
  final String month = dt.month.toString().padLeft(2, '0');
  final String day = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$month-$day';
}
