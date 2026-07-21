package app.forge.forge.widgets

/**
 * The Android mirror of the Dart `WidgetPlatformContract`
 * (lib/features/widgets/domain/widget_platform_contract.dart).
 *
 * These literals MUST stay byte-for-byte identical to the Dart side; a Dart
 * unit test (`platform_widget_host_channel_test.dart`) pins the same values so
 * a drift is caught in the fast tier. The app publishes redacted, versioned
 * snapshots over the method channel; this container only ever READS the shared
 * snapshot and never opens the encrypted database (R-WIDGET-002).
 */
object WidgetContract {
    const val HOST_CHANNEL = "app.forge.forge/widget_host"

    const val METHOD_PUBLISH = "publish"
    const val METHOD_CLEAR = "clear"
    const val METHOD_PUBLISH_SECRET = "publishSecret"

    const val DEEP_LINK_SCHEME = "forge"
    const val DEEP_LINK_HOST = "widget"
    const val DEEP_LINK_ACTION_PATH = "intent"
    const val DEEP_LINK_OPEN_PATH = "open"

    const val PARAM_ACTION = "action"
    const val PARAM_INTENT_ID = "intent_id"
    const val PARAM_ISSUED_AT = "issued_at_utc_micros"
    const val PARAM_PROFILE_ID = "profile_id"
    const val PARAM_SURFACE = "surface"
    const val PARAM_TARGET = "target_entity_id"
    const val PARAM_TOKEN = "token"

    /** Private SharedPreferences file that backs the shared container. */
    const val PREFERENCES_NAME = "forge_widgets"

    const val SECRET_STORAGE_KEY = "forge.widget.secret"

    fun snapshotStorageKey(surfaceWire: String): String =
        "forge.widget.snapshot.$surfaceWire"

    // Stable widget surfaces (mirror of WidgetSurface.wireName).
    const val SURFACE_TODAY_TASKS = "today_tasks"
    const val SURFACE_HABIT_CHECKLIST = "habit_checklist"
    const val SURFACE_QUICK_NOTE = "quick_note"
    const val SURFACE_STUDY_FOCUS = "study_focus_countdown"
    const val SURFACE_ROADMAP_PROGRESS = "roadmap_progress"

    // Widget intent actions (mirror of WidgetIntentAction.wireName).
    const val ACTION_COMPLETE_TASK = "complete_task"
    const val ACTION_CHECK_IN_HABIT = "check_in_habit"

    /** The snapshot schema version this container understands. */
    const val SUPPORTED_SNAPSHOT_VERSION = 1
}
