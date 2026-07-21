package app.forge.forge.widgets

import android.content.Context
import android.widget.RemoteViews
import app.forge.forge.R

/**
 * The five V1 mobile widget surfaces (R-WIDGET-001). Each is a distinct app
 * widget receiver so the launcher can offer them independently in
 * platform-appropriate sizes (declared per-provider in the res/xml widget
 * info resources).
 */

/** Today's overdue/today tasks; a check tap completes a task. */
class TodayTasksWidgetProvider : ForgeAppWidgetProvider() {
    override val surfaceWire: String = WidgetContract.SURFACE_TODAY_TASKS
    override val rowActionWire: String = WidgetContract.ACTION_COMPLETE_TASK
    override fun titleRes(): Int = R.string.widget_today_tasks_title
}

/** Today's habit occurrences; a check tap records a habit check-in. */
class HabitChecklistWidgetProvider : ForgeAppWidgetProvider() {
    override val surfaceWire: String = WidgetContract.SURFACE_HABIT_CHECKLIST
    override val rowActionWire: String = WidgetContract.ACTION_CHECK_IN_HABIT
    override fun titleRes(): Int = R.string.widget_habit_checklist_title
}

/**
 * Quick Note: opens secure capture and never exposes note content
 * (ux-design §13). Read-only surface with a single capture affordance.
 */
class QuickNoteWidgetProvider : ForgeAppWidgetProvider() {
    override val surfaceWire: String = WidgetContract.SURFACE_QUICK_NOTE
    override fun titleRes(): Int = R.string.widget_quick_note_title

    override fun renderItems(
        context: Context,
        views: RemoteViews,
        snapshot: WidgetSnapshot,
    ) {
        // Quick Note exposes no content; show the capture affordance only.
        showPlaceholder(views, context.getString(R.string.widget_quick_note_capture))
    }
}

/** Study/Focus countdown derived from a persisted target timestamp. */
class StudyFocusWidgetProvider : ForgeAppWidgetProvider() {
    override val surfaceWire: String = WidgetContract.SURFACE_STUDY_FOCUS
    override fun titleRes(): Int = R.string.widget_study_focus_title
}

/** Roadmap progress for a pinned goal (read-only glance). */
class RoadmapProgressWidgetProvider : ForgeAppWidgetProvider() {
    override val surfaceWire: String = WidgetContract.SURFACE_ROADMAP_PROGRESS
    override fun titleRes(): Int = R.string.widget_roadmap_progress_title
}
