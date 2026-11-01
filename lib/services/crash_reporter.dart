import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../build_info.dart';

/// Sends a short report to the `crash_reports` table (supabase/phase32.sql)
/// whenever the app hits an error, so problems testers run into show up
/// in the admin panel without anyone having to describe them. No extra
/// package — just Flutter's own error hooks. Never throws.
class CrashReporter {
  static final Map<String, int> _recent = {};
  static bool _installed = false;

  // Network hiccups and image loads failing aren't bugs — skip them.
  static const _noise = [
    'SocketException',
    'NetworkImageLoadException',
    'HTTP request failed',
    'Connection closed',
    'Connection reset',
    'ClientException',
    'TimeoutException',
    'HandshakeException',
  ];

  static void install() {
    if (_installed) return;
    _installed = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
      report(details.exception, details.stack, context: details.context?.toDescription());
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      report(error, stack, fatal: true);
      return true;
    };
  }

  static void report(Object error, StackTrace? stack, {String? context, bool fatal = false}) {
    try {
      var message = error.toString();
      if (_noise.any(message.contains)) return;
      if (message.length > 1000) message = message.substring(0, 1000);
      // The same error over and over (e.g. every frame) only counts once a minute.
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _recent[message];
      if (last != null && now - last < 60000) return;
      if (_recent.length > 100) _recent.clear();
      _recent[message] = now;

      var trace = stack?.toString();
      if (trace != null && trace.length > 6000) trace = trace.substring(0, 6000);
      var where = context;
      if (where != null && where.length > 500) where = where.substring(0, 500);
      var platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
      if (platform.length > 120) platform = platform.substring(0, 120);

      unawaited(() async {
        try {
          await Supabase.instance.client.from('crash_reports').insert({
            'message': message,
            'stack': trace,
            'context': where,
            'fatal': fatal,
            'build': appBuild,
            'platform': platform,
          });
        } catch (_) {
          // Offline or the table isn't there yet — nothing to do.
        }
      }());
    } catch (_) {}
  }
}
