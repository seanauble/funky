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

  // Party Mode's rainbow, drawn once per video size and reused every frame.
  private let rainbowLock = NSLock()
  private var rainbowCache: [String: CIImage] = [:]

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

    // An extra layer some filters paint over the colors: "rainbow" (Party
    // Mode, a rainbow that slides across) or "vignette" (2016's dark corners).
    let overlay: String = (args["overlay"] as? String) ?? ""
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
      var filtered: CIImage = source
      if let filter = CIFilter(name: "CIColorMatrix") {
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(r, forKey: "inputRVector")
        filter.setValue(g, forKey: "inputGVector")
        filter.setValue(b, forKey: "inputBVector")
        filter.setValue(a, forKey: "inputAVector")
        filter.setValue(bias, forKey: "inputBiasVector")
        filtered = filter.outputImage ?? source
      }
      if overlay == "rainbow" {
        let seconds: Double = CMTimeGetSeconds(request.compositionTime)
        filtered = self.addRainbow(to: filtered, extent: source.extent, seconds: seconds.isFinite ? seconds : 0)
      } else if overlay == "vignette" {
        filtered = FunkyVideoFilterPlugin.addVignette(to: filtered)
      }
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

extension FunkyVideoFilterPlugin {
  /// Party Mode: a semi-clear rainbow laid over the frame with an overlay
  /// blend, sliding sideways once every two seconds.
  fileprivate func addRainbow(to image: CIImage, extent: CGRect, seconds: Double) -> CIImage {
    guard let rainbow = rainbowImage(width: Int(extent.width), height: Int(extent.height)) else { return image }
    let period: Double = 2.0
    let phase: Double = seconds.truncatingRemainder(dividingBy: period) / period
    let shift = CGFloat(phase) * extent.width
    let moved = rainbow
      .transformed(by: CGAffineTransform(translationX: extent.origin.x - shift, y: extent.origin.y))
      .cropped(to: extent)
    guard let blend = CIFilter(name: "CIOverlayBlendMode") else { return image }
    blend.setValue(moved, forKey: kCIInputImageKey)
    blend.setValue(image, forKey: kCIInputBackgroundImageKey)
    return blend.outputImage ?? image
  }

  /// A rainbow twice as wide as the video (the colors repeat, so sliding it
  /// by one video-width loops without a seam).
  fileprivate func rainbowImage(width: Int, height: Int) -> CIImage? {
    if width <= 0 || height <= 0 { return nil }
    let key = "\(width)x\(height)"
    rainbowLock.lock()
    defer { rainbowLock.unlock() }
    if let cached = rainbowCache[key] { return cached }
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: width * 2,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let stops: [UIColor] = [
      UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.55),
      UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.55),
      UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.55),
      UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.55),
      UIColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 0.55),
      UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.55),
      UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 0.55),
      UIColor(red: 1.0, green: 0.18, blue: 0.57, alpha: 0.55),
    ]
    var colors: [CGColor] = []
    for _ in 0..<2 {
      for c in stops {
        colors.append(c.cgColor)
      }
    }
    colors.append(stops[0].cgColor)
    guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return nil }
    ctx.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: 0),
      end: CGPoint(x: CGFloat(width * 2), y: 0),
      options: []
    )
    guard let cg = ctx.makeImage() else { return nil }
    let image = CIImage(cgImage: cg)
    rainbowCache[key] = image
    return image
  }

  /// 2016: darker corners.
  fileprivate static func addVignette(to image: CIImage) -> CIImage {
    guard let vignette = CIFilter(name: "CIVignette") else { return image }
    vignette.setValue(image, forKey: kCIInputImageKey)
    vignette.setValue(0.9, forKey: kCIInputIntensityKey)
    vignette.setValue(1.6, forKey: kCIInputRadiusKey)
    return vignette.outputImage ?? image
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
