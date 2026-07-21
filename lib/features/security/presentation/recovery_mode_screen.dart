import 'package:flutter/material.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible Recovery-Mode surface (ux-design §"Restore", Error Handling).
///
/// Recovery Mode is entered when the runtime cannot open a trustworthy active
/// generation. It is always non-destructive: existing ciphertext and key
/// material are preserved (`R-SEC-001`), so this surface explains the problem,
/// reassures the user that nothing was deleted or reset, names the next
/// recovery step, and never replaces content with a blank screen (Error
/// Handling). It is a leaf surface shown before the shell, so it carries its
/// own [Scaffold].
///
/// Copy is specific and never color-only; the reason maps to a plain-language
/// explanation and the optional [RecoveryModeInfo.detail] is surfaced as a
/// redaction-safe technical note (ux-design §11, `NFR-A11Y-001`,
/// `NFR-A11Y-003`).
final class RecoveryModeScreen extends StatelessWidget {
  const RecoveryModeScreen({
    required this.info,
    this.onRetry,
    this.onRestore,
    this.onDiagnostics,
    super.key,
  });

  final RecoveryModeInfo info;

  /// Re-attempts opening the active generation. Null hides the action.
  final VoidCallback? onRetry;

  /// Opens the restore-from-backup flow. Null hides the action.
  final VoidCallback? onRestore;

  /// Opens local diagnostics. Null hides the action.
  final VoidCallback? onDiagnostics;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    final List<Widget> actions = <Widget>[
      if (onRestore != null)
        FilledButton.icon(
          onPressed: onRestore,
          icon: const Icon(Icons.settings_backup_restore),
          label: Text(l10n.recoveryActionRestore),
        ),
      if (onRetry != null)
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.recoveryActionRetry),
        ),
      if (onDiagnostics != null)
        TextButton.icon(
          onPressed: onDiagnostics,
          icon: const Icon(Icons.info_outline),
          label: Text(l10n.recoveryActionDiagnostics),
        ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ForgeSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.formMaxWidth,
              ),
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Icon(
                        Icons.health_and_safety_outlined,
                        size: ForgeSizes.minimumInteractiveDimension,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.md),
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.recoveryTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.sm),
                    Text(
                      _reasonMessage(l10n, info.reason),
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: ForgeSpacing.md),
                    _ReassuranceBanner(message: l10n.recoveryDataSafe),
                    if (info.detail case final String detail) ...<Widget>[
                      const SizedBox(height: ForgeSpacing.md),
                      Text(
                        l10n.recoveryDetail(detail),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (actions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: ForgeSpacing.lg),
                      Semantics(
                        header: true,
                        child: Text(
                          l10n.recoveryNextSteps,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: ForgeSpacing.sm),
                      Wrap(
                        spacing: ForgeSpacing.sm,
                        runSpacing: ForgeSpacing.sm,
                        children: actions,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _reasonMessage(AppLocalizations l10n, RecoveryReason reason) {
    return switch (reason) {
      RecoveryReason.keyUnavailable => l10n.recoveryReasonKeyUnavailable,
      RecoveryReason.pointerCorrupt => l10n.recoveryReasonPointerCorrupt,
      RecoveryReason.openFailed => l10n.recoveryReasonOpenFailed,
      RecoveryReason.verificationFailed =>
        l10n.recoveryReasonVerificationFailed,
    };
  }
}

/// A non-alarming banner that reassures the user their data is intact. Uses a
/// tonal container with an icon and text so the meaning is not color-only.
final class _ReassuranceBanner extends StatelessWidget {
  const _ReassuranceBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(ForgeRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.lock_outline, color: colors.onSecondaryContainer),
            const SizedBox(width: ForgeSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
