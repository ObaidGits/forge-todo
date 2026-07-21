import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ForgeWidgetHost") {
      ForgeWidgetHost.register(with: registrar)
    }
  }
}

/// The Runner mirror of the Dart `WidgetPlatformContract`. Kept inline so the
/// Runner target compiles without additional project membership; the WidgetKit
/// extension ships its own self-contained copy under `ios/ForgeWidgets/`.
enum WidgetContract {
  static let hostChannel = "app.forge.forge/widget_host"
  static let methodPublish = "publish"
  static let methodClear = "clear"
  static let methodPublishSecret = "publishSecret"
  static let paramSurface = "surface"
  static let secretStorageKey = "forge.widget.secret"
  static let iosAppGroup = "group.app.forge.forge.widgets"

  static func snapshotStorageKey(_ surfaceWire: String) -> String {
    "forge.widget.snapshot.\(surfaceWire)"
  }
}

/// The iOS side of the widget host method channel (task 11.2).
///
/// Mirrors the Android `ForgeWidgetHostPlugin`: it listens on the shared
/// `WidgetContract.hostChannel` and applies the app's local-only publishes to
/// the App Group container that the WidgetKit extension reads. It performs no
/// domain logic and never opens the encrypted database (R-WIDGET-002).
final class ForgeWidgetHost: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: WidgetContract.hostChannel,
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ForgeWidgetHost(), channel: channel)
  }

  private var defaults: UserDefaults? {
    UserDefaults(suiteName: WidgetContract.iosAppGroup)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let store = defaults else {
      result(FlutterError(code: "no_app_group",
                          message: "App Group is unavailable",
                          details: WidgetContract.iosAppGroup))
      return
    }
    switch call.method {
    case WidgetContract.methodPublish:
      guard let args = call.arguments as? [String: Any],
            let surface = args[WidgetContract.paramSurface] as? String,
            let payload = args["payload"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "surface and payload required", details: nil))
        return
      }
      store.set(payload, forKey: WidgetContract.snapshotStorageKey(surface))
      reload()
      result(nil)
    case WidgetContract.methodClear:
      guard let args = call.arguments as? [String: Any],
            let surface = args[WidgetContract.paramSurface] as? String
      else {
        result(FlutterError(code: "bad_args", message: "surface required", details: nil))
        return
      }
      store.removeObject(forKey: WidgetContract.snapshotStorageKey(surface))
      reload()
      result(nil)
    case WidgetContract.methodPublishSecret:
      guard let args = call.arguments as? [String: Any],
            let secret = args["secret"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "secret required", details: nil))
        return
      }
      store.set(secret, forKey: WidgetContract.secretStorageKey)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reload() {
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
