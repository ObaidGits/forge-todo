package app.forge.forge.widgets

import android.content.Context

/**
 * The local-only shared container the app writes and the widgets read
 * (R-WIDGET-002).
 *
 * Backed by a private [android.content.SharedPreferences] file. The app process
 * writes canonical snapshot JSON here through the method-channel host; the app
 * widget providers only ever read it. Nothing here touches the encrypted
 * database, and these values are never synced.
 */
object WidgetSharedStorage {
    /**
     * The `home_widget` plugin's private SharedPreferences file. The Dart
     * `HomeWidgetHostChannel` publishes snapshots/secret here via
     * `HomeWidget.saveWidgetData`, so the providers read it first.
     */
    private const val HOME_WIDGET_PREFERENCES = "HomeWidgetPreferences"

    /** The `home_widget` transport (production publish path). */
    private fun homeWidgetPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            HOME_WIDGET_PREFERENCES,
            Context.MODE_PRIVATE,
        )

    /** The legacy custom method-channel container (still supported/fallback). */
    private fun legacyPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            WidgetContract.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )

    fun writeSnapshot(context: Context, surfaceWire: String, payload: String) {
        legacyPrefs(context)
            .edit()
            .putString(WidgetContract.snapshotStorageKey(surfaceWire), payload)
            .apply()
    }

    fun clearSnapshot(context: Context, surfaceWire: String) {
        legacyPrefs(context)
            .edit()
            .remove(WidgetContract.snapshotStorageKey(surfaceWire))
            .apply()
    }

    fun readSnapshot(context: Context, surfaceWire: String): WidgetSnapshot? {
        val key = WidgetContract.snapshotStorageKey(surfaceWire)
        // Prefer the home_widget transport; fall back to the legacy container.
        val raw = homeWidgetPrefs(context).getString(key, null)
            ?: legacyPrefs(context).getString(key, null)
        return WidgetSnapshot.decode(raw)
    }

    fun writeSecret(context: Context, secret: String) {
        legacyPrefs(context)
            .edit()
            .putString(WidgetContract.SECRET_STORAGE_KEY, secret)
            .apply()
    }

    fun readSecret(context: Context): String? =
        homeWidgetPrefs(context).getString(WidgetContract.SECRET_STORAGE_KEY, null)
            ?: legacyPrefs(context).getString(WidgetContract.SECRET_STORAGE_KEY, null)
}
