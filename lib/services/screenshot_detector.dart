import 'package:flutter/services.dart';

/// Thin wrapper around a native iOS/Android screenshot notification — this
/// is a hand-written platform channel, not a third-party pub.dev plugin, on
/// purpose: a half-maintained screenshot-detection package is exactly the
/// kind of dependency that broke the iOS build once already this project
/// (see flutter_map_heatmap_plus). Native side: ios/Runner/AppDelegate.swift
/// and android/.../MainActivity.kt.
///
/// Caveat: this app's iOS project uses Flutter's newer UIScene-based
/// `FlutterImplicitEngineDelegate` template. As of when this was written,
/// there's an open, unresolved Flutter framework bug where a custom native
/// channel registered that way can silently fail to deliver messages
/// (flutter/flutter#185935). So: this is written correctly against Flutter's
/// own documented pattern, but if screenshots never register on a real
/// device, that upstream bug — not this code — is the likely reason.
class ScreenshotDetector {
  static const _channel = MethodChannel('com.funkyapp.funky/screenshot');
  static void Function()? _onScreenshot;
  static bool _listening = false;

  static void start(void Function() onScreenshot) {
    _onScreenshot = onScreenshot;
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshotTaken') {
        _onScreenshot?.call();
      }
    });
  }

  static void stop() {
    _onScreenshot = null;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }
}
