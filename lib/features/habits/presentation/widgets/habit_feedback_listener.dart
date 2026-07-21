import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Surfaces transient habit feedback near the command (ux-design §10). Every
/// confirmation is neutral and factual; a miss is never announced as a failure
/// of the user (R-HABIT-006).
void handleHabitFeedback(
  BuildContext context,
  WidgetRef ref,
  HabitFeedback feedback, {
  required void Function() dismiss,
}) {
  final AppLocalizations l10n = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  switch (feedback) {
    case HabitFeedbackNone():
      return;
    case HabitFeedbackMessage(messageCode: final String code):
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(HabitLabels.feedback(l10n, code))),
      );
    case HabitFeedbackError(failure: final failure):
      messenger.showSnackBar(
        SnackBar(content: Text(HabitLabels.failure(l10n, failure.code))),
      );
  }
  dismiss();
}
