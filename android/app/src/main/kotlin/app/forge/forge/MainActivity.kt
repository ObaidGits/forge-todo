package app.forge.forge

import app.forge.forge.widgets.ForgeWidgetHostPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The single Flutter host activity.
 *
 * Extends [FlutterFragmentActivity] (NOT `FlutterActivity`) because `local_auth`
 * requires a `FragmentActivity` to host the system BiometricPrompt for the app
 * lock (R-SEC-003). `singleTop` + the manifest intent-filters let the same
 * activity receive widget deep links (`forge://widget/...`) and `ACTION_SEND`
 * text/URL shares without spawning a second task.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register the widget host so the app can publish redacted snapshots to
        // the shared container that the home-screen widgets render from.
        flutterEngine.plugins.add(ForgeWidgetHostPlugin())
    }
}
