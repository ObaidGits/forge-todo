import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:go_router/go_router.dart';

/// The Today focus slot rendered by Home (R-HOME-001, R-HOME-003, R-FOCUS-001).
///
/// When a session is open it shows the running/paused state and opens
/// `/focus/<id>`; when none is open it offers to start a count-up session
/// without leaving Today (R-HOME-003). Home owns this widget and drives it
/// through the focus *application* command contract only (design.md §4/§16).
final class FocusSlotCard extends ConsumerWidget {
  const FocusSlotCard({required this.focus, super.key});

  /// The active focus session, or null when none is open.
  final FocusSlot? focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FocusSlot? active = focus;
    if (active != null) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: const ValueKey<String>('focus-active-tile'),
          leading: Icon(
            active.isRunning ? Icons.timelapse : Icons.pause_circle_outline,
          ),
          title: Text(
            active.isRunning
                ? context.l10n.homeFocusRunning
                : context.l10n.homeFocusPaused,
          ),
          subtitle: Text(_elapsedLabel(active)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/focus/${active.sessionId}'),
        ),
      );
    }

    final LifeAreaId? area = ref.watch(quickCaptureAreaProvider);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const ValueKey<String>('focus-start-tile'),
        leading: const Icon(Icons.play_circle_outline),
        title: Text(context.l10n.homeFocusStart),
        trailing: FilledButton(
          onPressed: area == null
              ? null
              : () => unawaited(
                  ref
                      .read(homeControllerProvider.notifier)
                      .startFocus(lifeAreaId: area),
                ),
          child: Text(context.l10n.homeFocusStart),
        ),
      ),
    );
  }

  String _elapsedLabel(FocusSlot slot) {
    final int totalSec = slot.accumulatedDurationSec;
    final int minutes = totalSec ~/ 60;
    final int seconds = totalSec % 60;
    final String mmss =
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    if (slot.linkLabel != null) {
      return '$mmss · ${slot.linkLabel}';
    }
    return mmss;
  }
}
