import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// The main back camera and the selfie camera. iPhones list more lenses
/// than that (telephoto, ultra-wide); flipping used to step through all of
/// them, which is why it sometimes landed on the zoomed-in telephoto.
int mainLens(List<CameraDescription> cameras, CameraLensDirection direction) {
  final i = cameras.indexWhere((c) => c.lensDirection == direction);
  return i < 0 ? 0 : i;
}

/// The lens a flip goes to: back → selfie, selfie → back.
int flippedLens(List<CameraDescription> cameras, int current) {
  if (cameras.isEmpty) return current;
  final front = current >= 0 && current < cameras.length && cameras[current].lensDirection == CameraLensDirection.front;
  final next = cameras.indexWhere((c) => c.lensDirection == (front ? CameraLensDirection.back : CameraLensDirection.front));
  return next < 0 ? current : next;
}

/// Sends zoom changes to the camera one at a time, always the newest. A
/// pinch fires 60+ updates a second; sending every one queued them up in
/// the camera, which is what made zoom lag behind your fingers and jump.
class ZoomPump {
  CameraController? _controller;
  double? _pending;
  bool _running = false;

  void set(CameraController controller, double zoom) {
    _controller = controller;
    _pending = zoom;
    if (!_running) _run();
  }

  Future<void> _run() async {
    _running = true;
    while (_pending != null) {
      final zoom = _pending!;
      _pending = null;
      final c = _controller;
      if (c == null) break;
      try {
        await c.setZoomLevel(zoom);
      } catch (_) {}
    }
    _running = false;
  }
}

/// The little "1.0×" pill over the shutter: shows the zoom and, tapped,
/// jumps between 1× and 2×.
class ZoomChip extends StatelessWidget {
  final double zoom;
  final VoidCallback onTap;
  const ZoomChip({super.key, required this.zoom, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = zoom < 9.95 ? '${zoom.toStringAsFixed(1)}×' : '${zoom.round()}×';
    final active = zoom > 1.05;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
        child: Text(
          label.replaceAll('.0×', '×'),
          style: TextStyle(color: active ? const Color(0xFFFFD60A) : Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
    );
  }
}
