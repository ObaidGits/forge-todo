package app.forge.forge.widgets

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * The Android side of the widget host method channel (task 11.2).
 *
 * Listens on [WidgetContract.HOST_CHANNEL] and applies the app's local-only
 * publishes to the shared container, then nudges the affected app widgets to
 * re-render. It only ever WRITES the redacted snapshot the app already built;
 * it performs no domain logic and never opens the encrypted database.
 */
class ForgeWidgetHostPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, WidgetContract.HOST_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val context = appContext
        if (context == null) {
            result.error("no_context", "Widget host is not attached", null)
            return
        }
        when (call.method) {
            WidgetContract.METHOD_PUBLISH -> {
                val surface = call.argument<String>(WidgetContract.PARAM_SURFACE)
                val payload = call.argument<String>("payload")
                if (surface == null || payload == null) {
                    result.error("bad_args", "surface and payload are required", null)
                    return
                }
                WidgetSharedStorage.writeSnapshot(context, surface, payload)
                refresh(context, surface)
                result.success(null)
            }

            WidgetContract.METHOD_CLEAR -> {
                val surface = call.argument<String>(WidgetContract.PARAM_SURFACE)
                if (surface == null) {
                    result.error("bad_args", "surface is required", null)
                    return
                }
                WidgetSharedStorage.clearSnapshot(context, surface)
                refresh(context, surface)
                result.success(null)
            }

            WidgetContract.METHOD_PUBLISH_SECRET -> {
                val secret = call.argument<String>("secret")
                if (secret == null) {
                    result.error("bad_args", "secret is required", null)
                    return
                }
                WidgetSharedStorage.writeSecret(context, secret)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun refresh(context: Context, surfaceWire: String) {
        val provider = providerFor(surfaceWire) ?: return
        ForgeAppWidgetProvider.requestUpdate(context, provider)
    }

    private fun providerFor(surfaceWire: String): Class<out ForgeAppWidgetProvider>? =
        when (surfaceWire) {
            WidgetContract.SURFACE_TODAY_TASKS -> TodayTasksWidgetProvider::class.java
            WidgetContract.SURFACE_HABIT_CHECKLIST -> HabitChecklistWidgetProvider::class.java
            WidgetContract.SURFACE_QUICK_NOTE -> QuickNoteWidgetProvider::class.java
            WidgetContract.SURFACE_STUDY_FOCUS -> StudyFocusWidgetProvider::class.java
            WidgetContract.SURFACE_ROADMAP_PROGRESS -> RoadmapProgressWidgetProvider::class.java
            else -> null
        }
}
