/// The production [WidgetHostChannel] backed by the `home_widget` plugin
/// (R-WIDGET-002, task 11.2).
///
/// This is the mobile transport that publishes the redacted, versioned snapshot
/// into the OS-shared container the native home-screen widgets read WITHOUT
/// ever opening the encrypted database. It serializes each snapshot through the
/// SAME canonical codec the in-memory/method-channel hosts use, writes it under
/// the SAME storage key the native providers read
/// ([WidgetPlatformContract.snapshotStorageKey]), and asks the plugin to nudge
/// the affected Android app-widget provider to re-render.
///
/// `package:home_widget` is imported ONLY here. Every call is bounded and
/// defensive: a missing widget host (no widget pinned, plugin unavailable)
/// degrades gracefully because [ForgeWidgetBridge] already retains the snapshot
/// in the local store and swallows a failed push — a widgetless device never
/// crashes or blocks the local-first app.
library;

import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_platform_contract.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:home_widget/home_widget.dart';

final class HomeWidgetHostChannel implements WidgetHostChannel {
  const HomeWidgetHostChannel();

  /// Fully-qualified Android provider class for each surface, so the plugin can
  /// broadcast an update to exactly the widgets that render that surface.
  static const Map<String, String>
  _androidProviderForSurface = <String, String>{
    'today_tasks': 'app.forge.forge.widgets.TodayTasksWidgetProvider',
    'habit_checklist': 'app.forge.forge.widgets.HabitChecklistWidgetProvider',
    'quick_note': 'app.forge.forge.widgets.QuickNoteWidgetProvider',
    'study_focus_countdown': 'app.forge.forge.widgets.StudyFocusWidgetProvider',
    'roadmap_progress': 'app.forge.forge.widgets.RoadmapProgressWidgetProvider',
  };

  @override
  Future<void> publish(WidgetSnapshot snapshot) async {
    await HomeWidget.saveWidgetData<String>(
      WidgetPlatformContract.snapshotStorageKey(
        WidgetSurface.fromWire(snapshot.surfaceWire) ??
            WidgetSurface.todayTasks,
      ),
      WidgetSnapshotCodec.encode(snapshot),
    );
    await _requestUpdate(snapshot.surfaceWire);
  }

  @override
  Future<void> clear(WidgetSurface surface) async {
    await HomeWidget.saveWidgetData<String>(
      WidgetPlatformContract.snapshotStorageKey(surface),
      null,
    );
    await _requestUpdate(surface.wireName);
  }

  /// Publishes the shared bridge [secret] so the native container can sign
  /// outbound widget intents. Called on unlock; the secret is local-only.
  Future<void> publishSecret(String secret) async {
    await HomeWidget.saveWidgetData<String>(
      WidgetPlatformContract.secretStorageKey,
      secret,
    );
  }

  Future<void> _requestUpdate(String surfaceWire) async {
    final String? provider = _androidProviderForSurface[surfaceWire];
    if (provider == null) {
      return;
    }
    await HomeWidget.updateWidget(qualifiedAndroidName: provider);
  }
}
