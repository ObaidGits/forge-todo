import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_edit.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A destructive-action confirmation that names the object and consequence and
/// previews the affected count (NFR-UX-002, ux-design §12). Returns true when
/// the user confirms.
Future<bool> showTaskConfirm({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final AppLocalizations l10n = context.l10n;
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.dialogKeep),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Prompts for the scope of a recurrence edit: this occurrence, or this and
/// future occurrences (R-TASK-007). Returns null when dismissed.
Future<RecurrenceEditScope?> showRecurrenceEditScope(
  BuildContext context,
) async {
  final AppLocalizations l10n = context.l10n;
  return showDialog<RecurrenceEditScope>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(l10n.recurrenceEditScopeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.recurrenceEditScopePrompt),
          const SizedBox(height: ForgeSpacing.sm),
          _ScopeOption(
            label: l10n.recurrenceEditThisOccurrence,
            onTap: () => Navigator.of(
              dialogContext,
            ).pop(RecurrenceEditScope.thisOccurrence),
          ),
          _ScopeOption(
            label: l10n.recurrenceEditThisAndFuture,
            onTap: () => Navigator.of(
              dialogContext,
            ).pop(RecurrenceEditScope.thisAndFuture),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.dialogCancel),
        ),
      ],
    ),
  );
}

final class _ScopeOption extends StatelessWidget {
  const _ScopeOption({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.event_repeat),
        title: Text(label),
        onTap: onTap,
      ),
    );
  }
}
