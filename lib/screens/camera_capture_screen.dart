import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// What `CameraCaptureScreen` hands back once the user has captured
/// something — exactly one of a photo or a (<=15s) video, never both.
class CapturedMedia {
  final File file;
  final bool isVideo;
  const CapturedMedia({required this.file, required this.isVideo});
}

const int _maxRecordMs = 15000;

/// A true in-app camera for Stories — our own live preview + capture
/// button, not the OS's camera/gallery picker sheet (the user was explicit
/// about this: "No image picker the it has to be taken from the app").
///
/// Tap the shutter for a photo. Press and hold it for a video, capped at
/// 15 seconds — recording auto-stops at the cap. While recording, the
/// shutter (and the screen edge) light up in a cycling rainbow "party
/// mode" glow, like a Juul flashing colors when shaken — just a fun,
/// unique bit of feedback that you're live-recording.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _ready = false;
  String? _error;

  bool _isRecording = false;
  DateTime? _recordStart;
  double _recordProgress = 0; // 0..1 of _maxRecordMs
  Timer? _recordTicker;
  bool _busy = false; // true while takePicture/startVideoRecording/stop in flight

  // Continuous hue-cycling animation that drives the "party mode" glow.
  // It's always running (cheap) but is only ever painted while recording.
  late final AnimationController _partyController =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  // Pinch-to-zoom — same approach as the Story camera tab (create_flow_screen.dart).
  double _minZoom = 1;
  double _maxZoom = 1;
  double _currentZoom = 1;
  double _baseZoom = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
  }

  Future<void> _setup() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }
      _cameras = cameras;
      _cameraIndex = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _openCamera(_cameraIndex);
    } catch (e) {
      setState(() => _error = 'Could not start the camera: $e');
    }
  }

  Future<void> _openCamera(int index) async {
    final previous = _controller;
    _controller = null;
    setState(() => _ready = false);
    await previous?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: true,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      var minZoom = 1.0;
      var maxZoom = 1.0;
      try {
        minZoom = await controller.getMinZoomLevel();
        maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {
        // Zoom queries aren't supported on every device — fall back to a
        // fixed 1x rather than crash.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraIndex = index;
        _ready = true;
        _error = null;
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = minZoom;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the camera: $e');
    }
  }

  void _onZoomStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  void _onZoomUpdate(ScaleUpdateDetails details) {
    final controller = _controller;
    if (controller == null || _maxZoom <= _minZoom) return;
    final zoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
    if (zoom == _currentZoom) return;
    _currentZoom = zoom;
    controller.setZoomLevel(zoom);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      controller.dispose();
      _controller = null;
      setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed) {
      _openCamera(_cameraIndex);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTicker?.cancel();
    _partyController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<Directory> _storiesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/stories');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy || _isRecording) return;
    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      final dir = await _storiesDir();
      final dest = '${dir.path}/story_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = await File(shot.path).copy(dest);
      if (!mounted) return;
      Navigator.of(context).pop(CapturedMedia(file: savedFile, isVideo: false));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not take the photo: $e');
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy || _isRecording) return;
    try {
      await controller.startVideoRecording();
      _recordStart = DateTime.now();
      setState(() {
        _isRecording = true;
        _recordProgress = 0;
      });
      _recordTicker = Timer.periodic(const Duration(milliseconds: 60), (_) {
        final start = _recordStart;
        if (start == null) return;
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        final progress = (elapsed / _maxRecordMs).clamp(0.0, 1.0);
        setState(() => _recordProgress = progress);
        if (elapsed >= _maxRecordMs) _stopRecording();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null || !_isRecording) return;
    _recordTicker?.cancel();
    _recordTicker = null;
    setState(() {
      _isRecording = false;
      _busy = true;
    });
    try {
      final raw = await controller.stopVideoRecording();
      final dir = await _storiesDir();
      final dest = '${dir.path}/story_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final savedFile = await File(raw.path).copy(dest);
      if (!mounted) return;
      Navigator.of(context).pop(CapturedMedia(file: savedFile, isVideo: true));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save the video: $e');
        setState(() => _busy = false);
      }
    }
  }

  void _cancelRecording() {
    // A short hold that gets released early counts as a cancel, same as
    // hitting the cap does a save — stopVideoRecording either way, the
    // user just lands with a very short clip which is fine.
    if (_isRecording) _stopRecording();
  }

  void _flipCamera() {
    if (_cameras.length < 2 || _busy || _isRecording) return;
    _openCamera((_cameraIndex + 1) % _cameras.length);
  }

  /// Same full-bleed trick as the Story camera tab — scales the already
  /// correctly-rotated CameraPreview up until it covers the screen instead
  /// of leaving black bars above/below it, cropping the overflow.
  Widget _buildFullBleedPreview(BuildContext context, CameraController controller) {
    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * controller.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;
    return ClipRect(
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.center,
        child: Center(child: CameraPreview(controller)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready && _controller != null)
            _buildFullBleedPreview(context, _controller!)
          else
            Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),

          // "Party mode" — a cycling rainbow glow traced around the edge
          // of the whole screen while recording, like lights flashing
          // around the frame. Painted above the preview, below the UI.
          if (_isRecording)
            AnimatedBuilder(
              animation: _partyController,
              builder: (context, _) => IgnorePointer(
                child: CustomPaint(
                  painter: _PartyBorderPainter(_partyController.value),
                  size: Size.infinite,
                ),
              ),
            ),

          // Pinch anywhere on the open preview to zoom. Sits behind the top
          // bar and shutter controls below it in the Stack, so it never
          // steals their taps — just the empty preview area.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onScaleStart: _onZoomStart,
              onScaleUpdate: _onZoomUpdate,
            ),
          ),

          // Top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundIconButton(
                    icon: Icons.close,
                    onTap: _isRecording ? null : () => Navigator.of(context).pop(),
                  ),
                  if (_isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        '${(_recordProgress * 15).toStringAsFixed(0)}s / 15s',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                  _RoundIconButton(
                    icon: Icons.flip_camera_ios,
                    onTap: _isRecording ? null : _flipCamera,
                  ),
                ],
              ),
            ),
          ),

          // Shutter + hint
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Visibility(maintainSize: ...) instead of an `if` — see the
                // matching comment in create_flow_screen.dart's camera tab:
                // removing this row outright shrinks the bottom-anchored
                // Column and shoves the shutter button down the instant
                // recording starts.
                Visibility(
                  visible: !_isRecording,
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: true,
                  child: const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text(
                      'Tap for a photo · Hold for a video',
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _takePhoto,
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _cancelRecording(),
                  onLongPressCancel: _cancelRecording,
                  child: AnimatedBuilder(
                    animation: _partyController,
                    builder: (context, _) => CustomPaint(
                      size: const Size(88, 88),
                      painter: _CaptureButtonPainter(
                        progress: _recordProgress,
                        recording: _isRecording,
                        partyT: _partyController.value,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: Icon(icon, color: onTap == null ? Colors.white38 : Colors.white),
      ),
    );
  }
}

/// A rainbow sweep traced around the capture button. At rest it's a plain
/// white ring with a thin dark outline. While recording, two things
/// happen at once: a red arc sweeps around the ring tracking progress
/// toward the 15s cap (same idea as before), and a blurred, continuously
/// rotating rainbow halo pulses behind it — the "party mode" effect.
class _CaptureButtonPainter extends CustomPainter {
  final double progress; // 0..1 toward the 15s cap
  final bool recording;
  final double partyT; // 0..1, loops continuously

  _CaptureButtonPainter({required this.progress, required this.recording, required this.partyT});

  Color _hue(double base) => HSVColor.fromAHSV(1, (base * 360) % 360, 0.9, 1).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outerRadius = size.width / 2;

    if (recording) {
      // Blurred, rotating rainbow glow halo — bigger than the button
      // itself so it reads as a glow around it, not just a ring on it.
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      final colors = List.generate(7, (i) => _hue(partyT + i / 6));
      glowPaint.shader = SweepGradient(
        colors: colors,
        transform: GradientRotation(partyT * 6.28318),
      ).createShader(Rect.fromCircle(center: center, radius: outerRadius + 6));
      canvas.drawCircle(center, outerRadius + 2, glowPaint);
    }

    // Base button fill.
    final fillPaint = Paint()..color = recording ? const Color(0xFFE53935) : Colors.white;
    canvas.drawCircle(center, outerRadius - 10, fillPaint);

    // Thin outer ring outline.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white;
    canvas.drawCircle(center, outerRadius - 4, ringPaint);

    if (recording) {
      // Progress arc toward the 15s cap, drawn on top of the ring.
      final progressPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = Colors.white;
      final rect = Rect.fromCircle(center: center, radius: outerRadius - 4);
      canvas.drawArc(rect, -1.5708, progress * 6.28318, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CaptureButtonPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.recording != recording || oldDelegate.partyT != partyT;
}

/// The screen-edge version of the same rainbow party-mode effect — a
/// blurred, rotating rainbow frame traced just inside the screen bounds.
class _PartyBorderPainter extends CustomPainter {
  final double t; // 0..1, loops continuously

  _PartyBorderPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final colors = List.generate(7, (i) => HSVColor.fromAHSV(1, ((t + i / 6) * 360) % 360, 0.95, 1).toColor());
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..shader = SweepGradient(
        colors: colors,
        transform: GradientRotation(t * 6.28318),
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _PartyBorderPainter oldDelegate) => oldDelegate.t != t;
}
