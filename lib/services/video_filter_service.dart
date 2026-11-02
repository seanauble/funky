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

  /// [overlay] is a filter's extra layer ('rainbow' for Party Mode,
  /// 'vignette' for 2016) — painted in by the same native export.
  static Future<String?> apply(String inputPath, String outputPath, List<double> matrix, {String? overlay}) async {
    try {
      final result = await _channel.invokeMethod<String>('apply', {
        'input': inputPath,
        'output': outputPath,
        'matrix': matrix,
        if (overlay != null) 'overlay': overlay,
      });
      return result;
    } catch (_) {
      return null;
    }
  }

  /// The "no change" color matrix, for a filter that's only an overlay.
  static const identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}
