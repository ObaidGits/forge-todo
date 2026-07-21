/// Publishes redacted, versioned widget snapshots from the app's local state
/// (R-WIDGET-002, R-WIDGET-004).
///
/// This is the app-side driver that turns the current Today agenda into the
/// glanceable snapshot the native home-screen widget renders. It runs on launch
/// and resume (next to the reminder reconcile) and after a committed capture,
/// so the widget reflects the local canonical state without ever opening the
/// encrypted database.
///
/// Every publish is lock-aware: when the app-lock session is locked OR the user
/// enabled "hide widget previews", the snapshot is redacted — no titles, no
/// counts (R-WIDGET-004). The publish path is bounded and fail-safe inside
/// [WidgetBridge.publish], so a widgetless device or an unavailable host never
/// blocks or crashes the local-first app.
library;

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

final class WidgetPublisher {
  const WidgetPublisher({
    required this.bridge,
    required this.builder,
    required this.clock,
    required this.taskQuery,
    required this.lock,
  });

  final WidgetBridge bridge;
  final WidgetSnapshotBuilder builder;
  final Clock clock;
  final TaskQueryService taskQuery;
  final AppLockGate lock;

  /// Rebuilds and publishes every V1 mobile surface for [profileId]. Best-effort
  /// and non-throwing: any failure to read/publish one surface is swallowed so a
  /// snapshot refresh never surfaces as an unhandled error.
  Future<void> publishAll(ProfileId profileId) async {
    // Content is visible only when the session is unlocked AND the user has not
    // asked to hide widget previews (R-WIDGET-004, R-SEC-003).
    final bool contentVisible = lock.widgetPreviewVisible();
    await _publishTodayTasks(profileId, contentVisible: contentVisible);
    await _publishRedactedShell(
      WidgetSurface.habitChecklist,
      profileId,
      contentVisible: contentVisible,
    );
  }

  Future<void> _publishTodayTasks(
    ProfileId profileId, {
    required bool contentVisible,
  }) async {
    List<WidgetSnapshotItem> items = const <WidgetSnapshotItem>[];
    if (contentVisible) {
      try {
        final DateTime nowUtc = clock.utcNow().toUtc();
        final DateTime start = DateTime.utc(
          nowUtc.year,
          nowUtc.month,
          nowUtc.day,
        );
        final String isoDate =
            '${start.year.toString().padLeft(4, '0')}-'
            '${start.month.toString().padLeft(2, '0')}-'
            '${start.day.toString().padLeft(2, '0')}';
        final TodayAgenda agenda = await taskQuery.todayAgenda(
          profileId: profileId,
          currentPlanningDate: isoDate,
          dayStartUtcMicros: start.microsecondsSinceEpoch,
          nowUtcMicros: nowUtc.microsecondsSinceEpoch,
        );
        // Overdue first, then due today — the actionable set a glance needs.
        items = <TaskSummary>[...agenda.overdue, ...agenda.dueToday]
            .map(
              (TaskSummary t) => WidgetSnapshotItem(
                id: t.id,
                title: t.title,
                subtitle: t.isOverdue ? 'Overdue' : null,
                isComplete: t.isCompleted,
              ),
            )
            .toList(growable: false);
      } on Object {
        // Fall back to an empty (but valid) content snapshot on any read error.
        items = const <WidgetSnapshotItem>[];
      }
    }
    final WidgetSnapshot snapshot = builder.build(
      surface: WidgetSurface.todayTasks,
      profileId: profileId,
      items: items,
      contentVisible: contentVisible,
    );
    await bridge.publish(snapshot);
  }

  /// Publishes a valid, lock-aware shell snapshot for a surface whose content
  /// projection is not yet sourced here (e.g. Habit Checklist). It still honours
  /// redaction and freshness so the native widget renders an honest state.
  Future<void> _publishRedactedShell(
    WidgetSurface surface,
    ProfileId profileId, {
    required bool contentVisible,
  }) async {
    final WidgetSnapshot snapshot = builder.build(
      surface: surface,
      profileId: profileId,
      items: const <WidgetSnapshotItem>[],
      contentVisible: contentVisible,
    );
    await bridge.publish(snapshot);
  }
}
