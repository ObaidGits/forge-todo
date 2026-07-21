import Foundation

/// The WidgetKit-extension mirror of the Dart `WidgetPlatformContract`
/// (lib/features/widgets/domain/widget_platform_contract.dart).
///
/// Self-contained so the extension target has no dependency on the Runner
/// target. Every literal MUST match the Dart contract and the Android mirror;
/// the Dart `platform_widget_host_channel_test.dart` pins these values.
enum WidgetContract {
  static let deepLinkScheme = "forge"
  static let deepLinkHost = "widget"
  static let deepLinkActionPath = "intent"
  static let deepLinkOpenPath = "open"

  static let paramAction = "action"
  static let paramIntentId = "intent_id"
  static let paramIssuedAt = "issued_at_utc_micros"
  static let paramProfileId = "profile_id"
  static let paramSurface = "surface"
  static let paramTarget = "target_entity_id"
  static let paramToken = "token"

  static let secretStorageKey = "forge.widget.secret"
  static let appGroup = "group.app.forge.forge.widgets"
  static let supportedSnapshotVersion = 1

  // Surface wire names (mirror of WidgetSurface.wireName).
  static let surfaceTodayTasks = "today_tasks"
  static let surfaceHabitChecklist = "habit_checklist"
  static let surfaceQuickNote = "quick_note"
  static let surfaceStudyFocus = "study_focus_countdown"
  static let surfaceRoadmapProgress = "roadmap_progress"

  // Intent action wire names (mirror of WidgetIntentAction.wireName).
  static let actionCompleteTask = "complete_task"
  static let actionCheckInHabit = "check_in_habit"

  static func snapshotStorageKey(_ surfaceWire: String) -> String {
    "forge.widget.snapshot.\(surfaceWire)"
  }
}
