import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/focus/domain/focus_preset.dart';
import 'package:forge/features/focus/presentation/focus_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The Focus screen: start and run a single focus session (R-FOCUS-001..004).
///
/// When the focus stack is not wired it shows a calm, accessible unavailable
/// state. When a session is open it shows a live-updating elapsed time derived
/// from the durable accumulated seconds plus the running segment (a cosmetic
/// tick — persistence stays anchor based, R-FOCUS-002) alongside keyboard
/// reachable Pause/Resume and End controls. Otherwise it offers a count-up start
/// and a few timed-block presets (R-FOCUS-004). It never claims to block
/// distractions (R-FOCUS-006).
final class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;

    if (!ref.watch(focusConfiguredProvider)) {
      return ForgeEmptyState(
        icon: Icons.timer_outlined,
        title: l10n.focusUnavailableTitle,
        body: l10n.focusUnavailableBody,
      );
    }

    final AsyncValue<FocusSessionView?> session = ref.watch(
      focusControllerProvider,
    );
    return session.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ForgeEmptyState(
        icon: Icons.error_outline,
        title: l10n.errorTitle,
        body: l10n.errorUnexpected,
      ),
      data: (FocusSessionView? view) => view == null
          ? const _FocusStartArea()
          : _FocusActiveSession(view: view),
    );
  }
}

/// The start area shown when no session is open: a count-up start plus timed
/// presets (R-FOCUS-004). Buttons are disabled when no default Life Area is
/// available, in which case starting a session is honestly unavailable.
final class _FocusStartArea extends ConsumerWidget {
  const _FocusStartArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final bool canStart = ref.watch(focusDefaultAreaProvider) != null;

    return ListView(
      restorationId: 'content-focus-start',
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
                  l10n.focusStartTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Text(
                l10n.focusStartBody,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: ForgeSpacing.lg),
              FilledButton.icon(
                key: const ValueKey<String>('focus-start-count-up'),
                onPressed: canStart
                    ? () => _run(
                        context,
                        () => ref
                            .read(focusControllerProvider.notifier)
                            .startCountUp(),
                      )
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.focusStartCountUp),
              ),
              const SizedBox(height: ForgeSpacing.sm),
              OutlinedButton.icon(
                key: const ValueKey<String>('focus-start-pomodoro'),
                onPressed: canStart
                    ? () => _run(
                        context,
                        () => ref
                            .read(focusControllerProvider.notifier)
                            .startPreset(FocusPreset.pomodoro),
                      )
                    : null,
                icon: const Icon(Icons.timelapse),
                label: Text(l10n.focusStartPomodoro),
              ),
              const SizedBox(height: ForgeSpacing.sm),
              OutlinedButton.icon(
                key: const ValueKey<String>('focus-start-deep-work'),
                onPressed: canStart
                    ? () => _run(
                        context,
                        () => ref
                            .read(focusControllerProvider.notifier)
                            .startPreset(FocusPreset.deepWork),
                      )
                    : null,
                icon: const Icon(Icons.hourglass_bottom),
                label: Text(l10n.focusStartDeepWork),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The active-session view. It rebuilds every second via [focusTickerProvider]
/// to recompute the cosmetic displayed elapsed time (R-FOCUS-002).
final class _FocusActiveSession extends ConsumerWidget {
  const _FocusActiveSession({required this.view});

  final FocusSessionView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);

    // Subscribe to the cosmetic ticker so the elapsed time updates each second
    // while running; the durable state is untouched (R-FOCUS-002).
    ref.watch<AsyncValue<int>>(focusTickerProvider);
    final int elapsedSec = view.displayedElapsedSec(
      ref.read(focusClockProvider).utcNow(),
    );
    final String elapsed = _formatDuration(elapsedSec);
    final String statusLabel = view.isRunning
        ? l10n.focusStatusRunning
        : l10n.focusStatusPaused;

    final String? link = _linkLabel(l10n, view.linkLabel);

    return ListView(
      restorationId: 'content-focus-active',
      padding: const EdgeInsets.all(ForgeSpacing.lg),
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ForgeSizes.readableContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // Status is conveyed by both an icon and a text label, never by
              // color alone (NFR-A11Y-003).
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    view.isRunning
                        ? Icons.timelapse
                        : Icons.pause_circle_outline,
                  ),
                  const SizedBox(width: ForgeSpacing.xs),
                  Text(statusLabel, style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: ForgeSpacing.md),
              Semantics(
                liveRegion: view.isRunning,
                label: l10n.focusElapsedSemantics(elapsed, statusLabel),
                child: ExcludeSemantics(
                  child: Text(
                    elapsed,
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Text(
                _modeLabel(l10n, view),
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
              const SizedBox(height: ForgeSpacing.xl),
              _FocusControls(view: view),
            ],
          ),
        ),
      ],
    );
  }

  String _modeLabel(AppLocalizations l10n, FocusSessionView view) {
    if (view.isInterval) {
      final int? planned = view.plannedDurationSec;
      if (planned != null) {
        return '${l10n.focusModeInterval} · '
            '${l10n.focusPlannedOf(_formatDuration(planned))}';
      }
      return l10n.focusModeInterval;
    }
    return l10n.focusModeCountUp;
  }
}

/// The Pause/Resume and End controls. Each is a full-width, keyboard-reachable
/// control that meets the 48dp minimum interactive size (NFR-A11Y-002) and
/// carries an explicit accessible label (NFR-A11Y-001).
final class _FocusControls extends ConsumerWidget {
  const _FocusControls({required this.view});

  final FocusSessionView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final FocusController controller = ref.read(
      focusControllerProvider.notifier,
    );
    final ButtonStyle fullWidth = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(
        ForgeSizes.minimumInteractiveDimension,
      ),
    );
    final ButtonStyle fullWidthOutlined = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(
        ForgeSizes.minimumInteractiveDimension,
      ),
    );

    return Column(
      children: <Widget>[
        if (view.isRunning)
          Semantics(
            button: true,
            label: l10n.focusPause,
            child: FilledButton.icon(
              key: const ValueKey<String>('focus-pause'),
              style: fullWidth,
              onPressed: () => _run(context, controller.pause),
              icon: const Icon(Icons.pause),
              label: Text(l10n.focusPause),
            ),
          )
        else
          Semantics(
            button: true,
            label: l10n.focusResume,
            child: FilledButton.icon(
              key: const ValueKey<String>('focus-resume'),
              style: fullWidth,
              onPressed: () => _run(context, controller.resume),
              icon: const Icon(Icons.play_arrow),
              label: Text(l10n.focusResume),
            ),
          ),
        const SizedBox(height: ForgeSpacing.sm),
        Semantics(
          button: true,
          label: l10n.focusEnd,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('focus-end'),
            style: fullWidthOutlined,
            onPressed: () => _run(context, controller.end),
            icon: const Icon(Icons.stop),
            label: Text(l10n.focusEnd),
          ),
        ),
      ],
    );
  }
}

/// Runs a command intent and surfaces a failure near the control (ux-design
/// Error Handling). Success is reflected by the reloaded session state.
void _run(
  BuildContext context,
  Future<Result<CommittedCommandResult>> Function() action,
) {
  unawaited(() async {
    final Result<CommittedCommandResult> result = await action();
    if (!context.mounted) {
      return;
    }
    if (result is Failed<CommittedCommandResult>) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_failureText(context, result.failure))),
      );
    }
  }());
}

String _failureText(BuildContext context, Failure failure) {
  final AppLocalizations l10n = context.l10n;
  return switch (failure.kind) {
    FailureKind.unavailableCapability => l10n.errorCapability,
    FailureKind.validation => l10n.errorValidation,
    FailureKind.conflict => l10n.errorConflict,
    FailureKind.permission => l10n.errorPermission,
    FailureKind.storage => l10n.errorStorage,
    FailureKind.network => l10n.errorNetwork,
    FailureKind.maintenanceLocked => l10n.errorMaintenance,
    FailureKind.unexpected => l10n.errorUnexpected,
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
