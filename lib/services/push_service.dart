import 'package:flutter/services.dart';

/// Thin wrapper around the hand-written iOS push channel (see
/// FunkyPushPlugin in ios/Runner/AppDelegate.swift) — no third-party
/// package. Everything is best-effort: on a platform/build without the
/// native side (or if the person says "Don't allow") the calls just do
/// nothing, and notifications still show up inside the app via the bell.
class PushService {
  static const _channel = MethodChannel('com.funkyapp.funky/push');
  static void Function(String token)? _onToken;
  static bool _listening = false;

  /// Asks for notification permission (the iOS prompt only ever shows once)
  /// and, if allowed, reports this phone's APNs token to [onToken] — now if
  /// it's already known, or whenever Apple hands it over.
  static Future<bool> start(void Function(String token) onToken) async {
    _onToken = onToken;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onToken') {
          final token = call.arguments as String?;
          if (token != null && token.isNotEmpty) _onToken?.call(token);
        }
        return null;
      });
    }
    try {
      final granted = await _channel.invokeMethod<bool>('requestPermission') ?? false;
      if (granted) {
        final token = await _channel.invokeMethod<String>('getToken');
        if (token != null && token.isNotEmpty) onToken(token);
      }
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// The red number on the app icon.
  static Future<void> setBadge(int count) async {
    try {
      await _channel.invokeMethod<void>('setBadge', count < 0 ? 0 : count);
    } catch (_) {}
  }
}
