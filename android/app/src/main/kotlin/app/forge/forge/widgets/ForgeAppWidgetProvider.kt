package app.forge.forge.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import app.forge.forge.R

/**
 * Base home-screen widget provider for every Forge surface (R-WIDGET-001).
 *
 * A provider renders ONLY from the redacted, versioned shared snapshot the app
 * published (R-WIDGET-002); it never opens the encrypted database. It honours
 * the snapshot's honest state (R-WIDGET-003/004):
 *
 *   * redacted snapshot  -> privacy placeholder (no titles, no counts);
 *   * stale snapshot     -> a "stale" badge alongside the last good content;
 *   * missing/undecodable -> a neutral "open Forge" placeholder.
 *
 * Check actions build a signed `forge://widget/intent` deep link that opens the
 * app; the app verifies and commits, then republishes a fresh snapshot. Taps
 * never optimistically mutate the widget.
 */
abstract class ForgeAppWidgetProvider : AppWidgetProvider() {

    /** The stable surface wire name this provider renders. */
    abstract val surfaceWire: String

    /** The action wire name for a row check tap, or null for read-only surfaces. */
    open val rowActionWire: String? = null

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context))
        }
    }

    /** Renders the current snapshot into a RemoteViews tree. */
    fun buildViews(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_forge)
        views.setTextViewText(R.id.widget_title, context.getString(titleRes()))
        views.removeAllViews(R.id.widget_items)

        // Tapping the header/body opens the surface in the app.
        views.setOnClickPendingIntent(
            R.id.widget_root,
            openPendingIntent(context, WidgetDeepLinks.buildOpenUri(surfaceWire)),
        )

        val snapshot = WidgetSharedStorage.readSnapshot(context, surfaceWire)
        if (snapshot == null) {
            showPlaceholder(views, context.getString(R.string.widget_placeholder_open))
            return views
        }

        val nowMicros = System.currentTimeMillis() * 1000L
        views.setViewVisibility(
            R.id.widget_stale_badge,
            if (snapshot.isStaleAt(nowMicros)) android.view.View.VISIBLE
            else android.view.View.GONE,
        )

        if (snapshot.redacted) {
            showPlaceholder(views, context.getString(R.string.widget_placeholder_locked))
            return views
        }

        if (snapshot.items.isEmpty()) {
            showPlaceholder(views, context.getString(R.string.widget_placeholder_empty))
            return views
        }

        views.setViewVisibility(R.id.widget_placeholder, android.view.View.GONE)
        renderItems(context, views, snapshot)
        return views
    }

    /** Default item rendering; surfaces may override for bespoke layouts. */
    protected open fun renderItems(
        context: Context,
        views: RemoteViews,
        snapshot: WidgetSnapshot,
    ) {
        var requestCode = surfaceWire.hashCode()
        for (item in snapshot.items) {
            val row = RemoteViews(context.packageName, R.layout.widget_row)
            row.setTextViewText(R.id.widget_row_title, item.title)
            if (item.subtitle != null) {
                row.setTextViewText(R.id.widget_row_subtitle, item.subtitle)
                row.setViewVisibility(R.id.widget_row_subtitle, android.view.View.VISIBLE)
            } else if (item.countdownRemainingSeconds != null) {
                row.setTextViewText(
                    R.id.widget_row_subtitle,
                    formatCountdown(item.countdownRemainingSeconds),
                )
                row.setViewVisibility(R.id.widget_row_subtitle, android.view.View.VISIBLE)
            } else {
                row.setViewVisibility(R.id.widget_row_subtitle, android.view.View.GONE)
            }

            row.setImageViewResource(
                R.id.widget_row_check,
                if (item.isComplete) R.drawable.ic_widget_check_on
                else R.drawable.ic_widget_check_off,
            )

            val actionWire = rowActionWire
            if (actionWire != null && !item.isComplete) {
                val uri = WidgetDeepLinks.buildActionUri(
                    signer = requireSigner(context),
                    actionWire = actionWire,
                    surfaceWire = surfaceWire,
                    profileId = snapshot.profileId,
                    targetEntityId = item.id,
                    issuedAtUtcMicros = System.currentTimeMillis() * 1000L,
                )
                row.setOnClickPendingIntent(
                    R.id.widget_row_check,
                    openPendingIntent(context, uri, requestCode++),
                )
            }
            views.addView(R.id.widget_items, row)
        }
    }

    protected fun showPlaceholder(views: RemoteViews, text: String) {
        views.setViewVisibility(R.id.widget_placeholder, android.view.View.VISIBLE)
        views.setTextViewText(R.id.widget_placeholder, text)
    }

    protected fun openPendingIntent(
        context: Context,
        uri: Uri,
        requestCode: Int = surfaceWire.hashCode(),
    ): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            setPackage(context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The signer used to authenticate a tap. If no secret has been published
     * yet (app never unlocked since install), a benign placeholder secret is
     * used so the produced token simply fails verification and the app opens
     * to a locked/pending state instead of committing.
     */
    protected fun requireSigner(context: Context): WidgetIntentSigner {
        val secret = WidgetSharedStorage.readSecret(context)
            ?: "unavailable-widget-secret" // >=16 chars; will fail verification
        return WidgetIntentSigner(secret)
    }

    protected fun formatCountdown(remainingSeconds: Long): String {
        val clamped = if (remainingSeconds < 0) 0 else remainingSeconds
        val hours = clamped / 3600
        val minutes = (clamped % 3600) / 60
        val seconds = clamped % 60
        return if (hours > 0) {
            String.format("%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format("%02d:%02d", minutes, seconds)
        }
    }

    protected abstract fun titleRes(): Int

    companion object {
        /** Requests a refresh of all instances of [provider]. */
        fun requestUpdate(context: Context, provider: Class<out ForgeAppWidgetProvider>) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isEmpty()) return
            val intent = Intent(context, provider).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            context.sendBroadcast(intent)
        }
    }
}
