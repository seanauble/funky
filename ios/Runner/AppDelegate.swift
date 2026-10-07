import Flutter
import UIKit
import UserNotifications
import AVFoundation
import CoreImage

/// Hand-written push-notification bridge (no third-party plugin): asks for
/// permission, registers with APNs, and hands the device token to Dart
/// over the `com.funkyapp.funky/push` channel. The server side (Supabase)
/// does the actual sending — see supabase/functions/send-push.
final class FunkyPushPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  static var shared: FunkyPushPlugin?

  private let channel: FlutterMethodChannel
  private var latestToken: String?
  // A tapped notification waits here until Dart is up and asks for it
  // (cold start); once Dart has asked, taps are delivered live.
  private var pendingOpen: [String: Any]?
  private var dartReady = false

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
    case "takePendingOpen":
      dartReady = true
      let p = pendingOpen
      pendingOpen = nil
      result(p)
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
    let info = response.notification.request.content.userInfo
    var payload: [String: Any] = [:]
    if let kind = info["kind"] as? String { payload["kind"] = kind }
    if let data = info["data"] as? [String: Any] { payload["data"] = data }
    if !payload.isEmpty {
      if dartReady {
        channel.invokeMethod("onOpen", arguments: payload)
      } else {
        pendingOpen = payload
      }
    }
    completionHandler()
  }
}

/// Bakes a 5x4 color matrix (the same numbers Flutter's ColorFilter.matrix
/// uses for the live preview) into a video, keeping its audio — so the
/// filter picked on the camera / review screen is what actually gets posted.
/// Called from lib/services/video_filter_service.dart.
final class FunkyVideoFilterPlugin: NSObject, FlutterPlugin {
  static var shared: FunkyVideoFilterPlugin?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.funkyapp.funky/videofilter",
      binaryMessenger: registrar.messenger()
    )
    let instance = FunkyVideoFilterPlugin()
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "apply",
          let args = call.arguments as? [String: Any],
          let input = args["input"] as? String,
          let output = args["output"] as? String,
          let rawMatrix = args["matrix"] as? [Any],
          rawMatrix.count == 20 else {
      result(FlutterMethodNotImplemented)
      return
    }

    let m: [Double] = rawMatrix.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    // Flutter's matrix works on 0-255 values (bias included); Core Image on 0-1.
    let r = CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: CGFloat(m[3]))
    let g = CIVector(x: CGFloat(m[5]), y: CGFloat(m[6]), z: CGFloat(m[7]), w: CGFloat(m[8]))
    let b = CIVector(x: CGFloat(m[10]), y: CGFloat(m[11]), z: CGFloat(m[12]), w: CGFloat(m[13]))
    let a = CIVector(x: CGFloat(m[15]), y: CGFloat(m[16]), z: CGFloat(m[17]), w: CGFloat(m[18]))
    let bias = CIVector(
      x: CGFloat(m[4] / 255.0),
      y: CGFloat(m[9] / 255.0),
      z: CGFloat(m[14] / 255.0),
      w: CGFloat(m[19] / 255.0)
    )
    // No color-space conversion, so the math lands the same way it does in
    // the Flutter preview (which applies the matrix to the encoded values).
    let context = CIContext(options: [CIContextOption.workingColorSpace: NSNull()])

    let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
      let source = request.sourceImage
      guard let filter = CIFilter(name: "CIColorMatrix") else {
        request.finish(with: source, context: nil)
        return
      }
      filter.setValue(source, forKey: kCIInputImageKey)
      filter.setValue(r, forKey: "inputRVector")
      filter.setValue(g, forKey: "inputGVector")
      filter.setValue(b, forKey: "inputBVector")
      filter.setValue(a, forKey: "inputAVector")
      filter.setValue(bias, forKey: "inputBiasVector")
      let filtered = filter.outputImage ?? source
      request.finish(with: filtered.cropped(to: source.extent), context: context)
    })

    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      result(FlutterError(code: "export_unavailable", message: "Could not start the video export", details: nil))
      return
    }
    let outputURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outputURL)
    export.outputURL = outputURL
    export.outputFileType = .mp4
    export.videoComposition = composition
    export.shouldOptimizeForNetworkUse = true
    export.exportAsynchronously {
      DispatchQueue.main.async {
        if export.status == .completed {
          result(output)
        } else {
          result(FlutterError(
            code: "export_failed",
            message: export.error?.localizedDescription ?? "The video export failed",
            details: nil
          ))
        }
      }
    }
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

    if let filterRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "FunkyVideoFilterPlugin") {
      FunkyVideoFilterPlugin.register(with: filterRegistrar)
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
