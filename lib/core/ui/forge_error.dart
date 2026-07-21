import 'package:flutter/material.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';

final class ForgeErrorView extends StatelessWidget {
  const ForgeErrorView({
    required this.title,
    required this.message,
    this.onRetry,
    this.onReturnToday,
    super.key,
  });

  factory ForgeErrorView.forFailure({
    required BuildContext context,
    required Failure failure,
    VoidCallback? onRetry,
    VoidCallback? onReturnToday,
    Key? key,
  }) => ForgeErrorView(
    key: key,
    title: context.l10n.errorTitle,
    message: localizedFailureMessage(context, failure),
    onRetry: failure.retryable ? onRetry : null,
    onReturnToday: onReturnToday,
  );

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onReturnToday;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ForgeSpacing.lg),
        child: Semantics(
          container: true,
          liveRegion: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: ForgeSizes.minimumInteractiveDimension,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: ForgeSpacing.md),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.sm),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: ForgeSpacing.lg),
                Wrap(
                  spacing: ForgeSpacing.sm,
                  runSpacing: ForgeSpacing.sm,
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    if (onRetry != null)
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.actionRetry),
                      ),
                    if (onReturnToday != null)
                      OutlinedButton.icon(
                        onPressed: onReturnToday,
                        icon: const Icon(Icons.today_outlined),
                        label: Text(context.l10n.actionReturnToday),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class ForgeInlineError extends StatelessWidget {
  const ForgeInlineError({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(ForgeRadii.control),
        ),
        child: Padding(
          padding: const EdgeInsets.all(ForgeSpacing.md),
          child: Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: colors.onErrorContainer),
              const SizedBox(width: ForgeSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
              if (onRetry != null)
                IconButton(
                  onPressed: onRetry,
                  tooltip: context.l10n.actionRetry,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String localizedFailureMessage(BuildContext context, Failure failure) {
  return switch (failure.kind) {
    FailureKind.validation => context.l10n.errorValidation,
    FailureKind.permission => context.l10n.errorPermission,
    FailureKind.storage => context.l10n.errorStorage,
    FailureKind.network => context.l10n.errorNetwork,
    FailureKind.conflict => context.l10n.errorConflict,
    FailureKind.unavailableCapability => context.l10n.errorCapability,
    FailureKind.maintenanceLocked => context.l10n.errorMaintenance,
    FailureKind.unexpected => context.l10n.errorUnexpected,
  };
}
