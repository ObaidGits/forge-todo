import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/goals/presentation/goal_labels.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Surfaces transient goal/roadmap feedback near the command (ux-design §10):
/// reversible Undo, an error message, or a subtle milestone celebration
/// (R-GOAL-006). Snackbars are reserved for Undo and cross-screen consequences;
/// the celebration is announced politely for assistive technology and honours
/// reduced motion (it is a static, dismissible message, never confetti).
void handleGoalFeedback(
  BuildContext context,
  WidgetRef ref,
  GoalFeedback feedback, {
  required void Function() dismiss,
}) {
  final AppLocalizations l10n = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  switch (feedback) {
    case GoalFeedbackNone():
      return;
    case GoalFeedbackUndo(offer: final GoalUndo offer):
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(_undoMessage(l10n, offer.messageCode)),
          action: SnackBarAction(
            label: l10n.actionUndo,
            onPressed: () => unawaited(offer.undo()),
          ),
        ),
      );
    case GoalFeedbackError(failure: final failure):
      messenger.showSnackBar(
        SnackBar(content: Text(GoalLabels.failure(l10n, failure.code))),
      );
    case GoalFeedbackCelebrate():
      // The visible celebration banner is rendered by the detail screen as a
      // `liveRegion`, so assistive technology announces it automatically; it is
      // dismissible and respects reduced motion. No imperative announcement is
      // needed here (R-GOAL-006).
      break;
  }
  dismiss();
}

String _undoMessage(AppLocalizations l10n, String code) => switch (code) {
  'archived' => l10n.goalUndoArchived,
  'unarchived' => l10n.goalUndoUnarchived,
  _ => l10n.goalUndoDone,
};
