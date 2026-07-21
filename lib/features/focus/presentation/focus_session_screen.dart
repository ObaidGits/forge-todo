import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/focus/application/focus_session_read_contract.dart';
import 'package:forge/features/focus/presentation/focus_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A read-only detail surface for one focus session (R-FOCUS-002, R-FOCUS-003).
///
/// It re-projects the durable session facts — visible status, mode, accumulated
/// work time, optional planned length and linked entity, and the projected
/// work/pause intervals — from the local generation, so the detail is available
/// offline (R-GEN-001). Status is conveyed by both an icon and a text label,
/// never colour alone (NFR-A11Y-003). Elapsed time is the durable accumulated
/// anchor; this surface never ticks a live segment (R-FOCUS-002) and offers no
/// corrections (it is read-only detail).
final class FocusSessionScreen extends ConsumerWidget {
  const FocusSessionScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<FocusSessionDetail?> detail = ref.watch(
      focusSessionDetailProvider(sessionId),
    );

    return detail.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ForgeEmptyState(
        icon: Icons.error_outline,
        title: l10n.errorTitle,
        body: l10n.errorUnexpected,
      ),
      data: (FocusSessionDetail? data) {
        if (data == null) {
          return ForgeEmptyState(
            icon: Icons.timer_outlined,
            title: l10n.focusSessionTitle,
            body: l10n.focusSessionNotFound,
          );
        }
        return _Detail(detail: data);
      },
    );
  }
}

final class _Detail extends StatelessWidget {
  const _Detail({required this.detail});

  final FocusSessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String statusLabel = _statusLabel(l10n, detail.statusWire);
    final String elapsed = _formatDuration(detail.accumulatedDurationSec);
    final String? link = _linkLabel(l10n, detail.linkLabel);

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-focus-session-${detail.sessionId}',
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
                    l10n.focusSessionTitle,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.sm),
                // Status carried by an icon plus a text label (NFR-A11Y-003).
                Row(
                  children: <Widget>[
                    Icon(_statusIcon(detail.statusWire), size: 20),
                    const SizedBox(width: ForgeSpacing.xs),
                    Text(statusLabel, style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: ForgeSpacing.xxs),
                Text(
                  _modeLabel(l10n, detail),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (link != null) ...<Widget>[
                  const SizedBox(height: ForgeSpacing.xxs),
                  Text(
                    l10n.focusLinkedTo(link),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: ForgeSpacing.md),
                Semantics(
                  label: '${l10n.focusElapsedLabel}: $elapsed',
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(ForgeSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.focusElapsedLabel,
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: ForgeSpacing.xxs),
                          ExcludeSemantics(
                            child: Text(
                              elapsed,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                Text(
                  l10n.focusStartedOn(_formatDateTime(detail.startedAtUtc)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.focusIntervalsLabel,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                if (detail.intervals.isEmpty)
                  Text(
                    l10n.focusNoIntervals,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (int i = 0; i < detail.intervals.length; i++)
                    _IntervalTile(
                      key: ValueKey<String>('focus-interval-$i'),
                      interval: detail.intervals[i],
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(AppLocalizations l10n, FocusSessionDetail detail) {
    if (detail.isInterval) {
      final int? planned = detail.plannedDurationSec;
      if (planned != null) {
        return '${l10n.focusModeInterval} · '
            '${l10n.focusPlannedOf(_formatDuration(planned))}';
      }
      return l10n.focusModeInterval;
    }
    return l10n.focusModeCountUp;
  }
}

final class _IntervalTile extends StatelessWidget {
  const _IntervalTile({required this.interval, super.key});

  final FocusIntervalView interval;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String kind = interval.kindWire == 'pause'
        ? l10n.focusIntervalPause
        : l10n.focusIntervalWork;
    final String duration = _formatDuration(interval.durationSec);
    final IconData icon = interval.kindWire == 'pause'
        ? Icons.pause_circle_outline
        : Icons.timelapse;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20),
            const SizedBox(width: ForgeSpacing.xs),
            Expanded(child: Text(l10n.focusIntervalLine(kind, duration))),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(AppLocalizations l10n, String statusWire) {
  return switch (statusWire) {
    'running' => l10n.focusStatusRunning,
    'paused' => l10n.focusStatusPaused,
    'completed' => l10n.focusStatusCompleted,
    'cancelled' => l10n.focusStatusCancelled,
    _ => statusWire,
  };
}

IconData _statusIcon(String statusWire) {
  return switch (statusWire) {
    'running' => Icons.timelapse,
    'paused' => Icons.pause_circle_outline,
    'completed' => Icons.check_circle_outline,
    'cancelled' => Icons.cancel_outlined,
    _ => Icons.help_outline,
  };
}

String? _linkLabel(AppLocalizations l10n, String? wire) {
  return switch (wire) {
    'task' => l10n.focusLinkTask,
    'course' => l10n.focusLinkCourse,
    'goal' => l10n.focusLinkGoal,
    'habit' => l10n.focusLinkHabit,
    _ => null,
  };
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

String _formatDateTime(int utcMicros) {
  final DateTime dt = DateTime.fromMicrosecondsSinceEpoch(
    utcMicros,
    isUtc: true,
  );
  String two(int value) => value.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
