import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Transient status of an in-progress recovery-center restore.
enum RecoveryCenterStatus { idle, restoring, restored, failed }

/// The full recovery center surface (`R-BACKUP-003`, `R-BACKUP-004`, V1 "full
/// recovery center"). It lists available recovery points and drives the
/// existing staged generation restore.
///
/// It builds on the Recovery-Mode language: restore is always non-destructive
/// until the atomic switch, and the copy reassures the user their current data
/// stays active if anything fails. The surface is fully accessible — every
/// point is a labeled, keyboard-reachable control with a 48dp target, status is
/// announced via a live region, and nothing relies on color alone (ux-design
/// §7 "Restore", §11, `NFR-A11Y-001`, `NFR-A11Y-003`).
final class RecoveryCenterScreen extends StatelessWidget {
  const RecoveryCenterScreen({
    required this.points,
    required this.onRestore,
    this.status = RecoveryCenterStatus.idle,
    this.busyPointId,
    super.key,
  });

  /// Recovery points to list, newest first.
  final List<RecoveryPoint> points;

  /// Invoked when the user chooses to restore a point.
  final void Function(RecoveryPoint point) onRestore;

  final RecoveryCenterStatus status;

  /// The point currently being restored, if any, so its control shows progress.
  final String? busyPointId;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool busy = status == RecoveryCenterStatus.restoring;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.recoveryCenterTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ForgeSizes.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(ForgeSpacing.lg),
              children: <Widget>[
                Text(
                  l10n.recoveryCenterIntro,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: ForgeSpacing.md),
                _StatusBanner(status: status),
                const SizedBox(height: ForgeSpacing.md),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.recoveryCenterPointsHeader,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.sm),
                if (points.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: ForgeSpacing.md,
                    ),
                    child: Text(
                      l10n.recoveryCenterEmpty,
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                else
                  for (final RecoveryPoint point in points)
                    _RecoveryPointTile(
                      point: point,
                      enabled: !busy,
                      busy: busy && busyPointId == point.id,
                      onRestore: () => onRestore(point),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});

  final RecoveryCenterStatus status;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (String message, IconData icon, Color background, Color foreground)?
    banner = switch (status) {
      RecoveryCenterStatus.idle => null,
      RecoveryCenterStatus.restoring => (
        l10n.recoveryCenterRestoring,
        Icons.sync,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      RecoveryCenterStatus.restored => (
        l10n.recoveryCenterRestored,
        Icons.check_circle_outline,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      RecoveryCenterStatus.failed => (
        l10n.recoveryCenterFailed,
        Icons.error_outline,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };
    if (banner == null) {
      return const SizedBox.shrink();
    }
    final (String message, IconData icon, Color background, Color foreground) =
        banner;
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(ForgeRadii.card),
        ),
        child: Padding(
          padding: const EdgeInsets.all(ForgeSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: foreground),
              const SizedBox(width: ForgeSpacing.sm),
              Expanded(
                child: Text(message, style: TextStyle(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _RecoveryPointTile extends StatelessWidget {
  const _RecoveryPointTile({
    required this.point,
    required this.enabled,
    required this.busy,
    required this.onRestore,
  });

  final RecoveryPoint point;
  final bool enabled;
  final bool busy;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String sourceLabel = switch (point.source) {
      RecoverySource.userBackup => l10n.recoveryCenterSourceUserBackup,
      RecoverySource.safetyBackup => l10n.recoveryCenterSourceSafetyBackup,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: ForgeSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(point.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: ForgeSpacing.xs),
            Row(
              children: <Widget>[
                Icon(
                  point.source == RecoverySource.safetyBackup
                      ? Icons.shield_outlined
                      : Icons.save_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: ForgeSpacing.xs),
                Text(sourceLabel, style: theme.textTheme.bodySmall),
                const SizedBox(width: ForgeSpacing.sm),
                Text(
                  l10n.recoveryCenterSize(point.sizeBytes),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: ForgeSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: enabled ? onRestore : null,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.settings_backup_restore),
                label: Text(l10n.recoveryCenterRestoreShort),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
