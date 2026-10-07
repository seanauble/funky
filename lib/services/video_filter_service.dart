import 'package:flutter/services.dart';

/// Bakes a color-matrix filter (the same 20-number matrix the live preview
/// uses — see cameraFilters in widgets/ui_widgets.dart) permanently into a
/// video file, so the filter you picked is what actually gets posted/saved.
/// Hand-written native iOS code (FunkyVideoFilterPlugin in
/// ios/Runner/AppDelegate.swift, Core Image + AVFoundation) — no extra
/// package. Returns the new file's path, or null if it couldn't be done
/// (callers decide whether to fall back to the unfiltered video).
class VideoFilterService {
  static const _channel = MethodChannel('com.funkyapp.funky/videofilter');

  static Future<String?> apply(String inputPath, String outputPath, List<double> matrix) async {
    try {
      final result = await _channel.invokeMethod<String>('apply', {
        'input': inputPath,
        'output': outputPath,
        'matrix': matrix,
      });
      return result;
    } catch (_) {
      return null;
    }
  }
}
