import Flutter
import UIKit

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
