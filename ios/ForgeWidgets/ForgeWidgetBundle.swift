import WidgetKit
import SwiftUI

/// The Forge WidgetKit bundle: the five V1 mobile surfaces (R-WIDGET-001) in
/// platform-appropriate families. Small prioritizes next task/focus; medium
/// shows 3-5 tasks/habits; large combines Today/roadmap (ux-design §13).
@main
struct ForgeWidgetBundle: WidgetBundle {
  var body: some Widget {
    TodayTasksWidget()
    HabitChecklistWidget()
    QuickNoteWidget()
    StudyFocusWidget()
    RoadmapProgressWidget()
  }
}

struct TodayTasksWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetContract.surfaceTodayTasks,
      provider: ForgeWidgetProvider(surfaceWire: WidgetContract.surfaceTodayTasks)
    ) { entry in
      ForgeWidgetView(
        entry: entry, title: "Today",
        actionWire: WidgetContract.actionCompleteTask, exposesContent: true)
    }
    .configurationDisplayName("Today")
    .description("Today's tasks with quick complete.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct HabitChecklistWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetContract.surfaceHabitChecklist,
      provider: ForgeWidgetProvider(surfaceWire: WidgetContract.surfaceHabitChecklist)
    ) { entry in
      ForgeWidgetView(
        entry: entry, title: "Habits",
        actionWire: WidgetContract.actionCheckInHabit, exposesContent: true)
    }
    .configurationDisplayName("Habits")
    .description("Today's habits with quick check-in.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct QuickNoteWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetContract.surfaceQuickNote,
      provider: ForgeWidgetProvider(surfaceWire: WidgetContract.surfaceQuickNote)
    ) { entry in
      ForgeWidgetView(
        entry: entry, title: "Quick Note",
        actionWire: nil, exposesContent: false)
    }
    .configurationDisplayName("Quick Note")
    .description("Open secure quick capture.")
    .supportedFamilies([.systemSmall])
  }
}

struct StudyFocusWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetContract.surfaceStudyFocus,
      provider: ForgeWidgetProvider(surfaceWire: WidgetContract.surfaceStudyFocus)
    ) { entry in
      ForgeWidgetView(
        entry: entry, title: "Focus",
        actionWire: nil, exposesContent: true)
    }
    .configurationDisplayName("Focus")
    .description("Next focus/study countdown.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct RoadmapProgressWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetContract.surfaceRoadmapProgress,
      provider: ForgeWidgetProvider(surfaceWire: WidgetContract.surfaceRoadmapProgress)
    ) { entry in
      ForgeWidgetView(
        entry: entry, title: "Roadmap",
        actionWire: nil, exposesContent: true)
    }
    .configurationDisplayName("Roadmap")
    .description("Pinned goal roadmap progress.")
    .supportedFamilies([.systemLarge])
  }
}
