import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/presentation/task_labels.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Surfaces the latest [TaskFeedback] as a SnackBar near the command: a
/// reversible action offers immediate Undo (R-GEN-003, R-TASK-009); a failure
/// shows a specific, non-color-only message (ux-design Error Handling).
///
/// The snackbar list is cleared before each show so that if more than one
/// screen observes the same feedback transition, only a single snackbar
/// remains visible on the shared messenger.
void handleTaskFeedback(
  BuildContext context,
  WidgetRef ref,
  TaskFeedback feedback,
) {
  final AppLocalizations l10n = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  switch (feedback) {
    case TaskFeedbackNone():
      return;
    case TaskFeedbackUndo(offer: final offer):
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(_undoMessage(l10n, offer.messageCode)),
          action: SnackBarAction(
            label: l10n.actionUndo,
            onPressed: () => unawaited(offer.undo()),
          ),
        ),
      );
    case TaskFeedbackError(failure: final failure):
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(content: Text(TaskLabels.failure(l10n, failure.code))),
      );
  }
}

String _undoMessage(AppLocalizations l10n, String code) => switch (code) {
  'completed' => l10n.taskUndoCompleted,
  'reopened' => l10n.taskUndoReopened,
  'deleted' => l10n.taskUndoDeleted,
  'completedMany' => l10n.taskUndoCompletedMany,
  'deletedMany' => l10n.taskUndoDeletedMany,
  _ => l10n.taskUndoCompleted,
};
