import Flutter
import UIKit
import UserNotifications

/// Hand-written push-notification bridge (no third-party plugin): asks for
/// permission, registers with APNs, and hands the device token to Dart
/// over the `com.funkyapp.funky/push` channel. The server side (Supabase)
/// does the actual sending — see supabase/functions/send-push.
final class FunkyPushPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  static var shared: FunkyPushPlugin?

  private let channel: FlutterMethodChannel
  private var latestToken: String?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.funkyapp.funky/push",
      binaryMessenger: registrar.messenger()
    )
    let instance = FunkyPushPlugin(channel: channel)
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    UNUserNotificationCenter.current().delegate = instance
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      let center = UNUserNotificationCenter.current()
      center.delegate = self
      center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
        DispatchQueue.main.async {
          if granted {
            UIApplication.shared.registerForRemoteNotifications()
          }
          result(granted)
        }
      }
    case "getToken":
      result(latestToken)
    case "setBadge":
      let count = (call.arguments as? Int) ?? 0
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = count
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - APNs registration callbacks (forwarded by FlutterAppDelegate)

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    latestToken = token
    channel.invokeMethod("onToken", arguments: token)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Nothing to do — the app just won't get pushes until the next launch.
  }

  // MARK: - UNUserNotificationCenterDelegate

  // Show the banner even while the app is open.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound, .badge])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}

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

    if let pushRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "FunkyPushPlugin") {
      FunkyPushPlugin.register(with: pushRegistrar)
    }

    // Story-viewer screenshot detection — a hand-written channel (no
    // third-party plugin) over Flutter's own built-in screenshot
    // notification, per Flutter's documented pattern for this UIScene-based
    // app template.
    let screenshotChannel = FlutterMethodChannel(
      name: "com.funkyapp.funky/screenshot",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    NotificationCenter.default.addObserver(
      forName: UIApplication.userDidTakeScreenshotNotification,
      object: nil,
      queue: .main
    ) { _ in
      screenshotChannel.invokeMethod("screenshotTaken", arguments: nil)
    }
  }
}
