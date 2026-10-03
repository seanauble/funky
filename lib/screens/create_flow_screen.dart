import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../widgets/kind_picker.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'place_detail_screen.dart';

const int _maxRecordMs = 15000;

const _tabLabels = ['CAMERA', 'TEXT', 'POLL', 'PLACE'];

int _pageIndexForKind(CreateKind kind) {
  switch (kind) {
    case CreateKind.story:
      return 0; // Straight to the camera — that's the whole point of "+".
    case CreateKind.poll:
      return 2;
    case CreateKind.place:
      return 3;
  }
}

/// What used to be a bottom sheet (Story/Poll/Place) is now a full-screen,
/// camera-first flow: tapping "+" opens straight into the live camera, and
/// you swipe left/right — or tap the little CAMERA / TEXT / POLL / PLACE
/// strip at the bottom — to reach a text-only Story, a poll, or a place
/// instead. `initial` just decides which page it opens on (the "Ask a
/// poll"/"Add a place" shortcuts elsewhere in the app still land directly
/// on those tabs; posting a camera Story is still one swipe away from
/// there, same as everything else).
class CreateFlowScreen extends StatefulWidget {
  final CreateKind initial;
  const CreateFlowScreen({super.key, this.initial = CreateKind.story});

  @override
  State<CreateFlowScreen> createState() => _CreateFlowScreenState();
}

class _CreateFlowScreenState extends State<CreateFlowScreen> {
  late int _page = _pageIndexForKind(widget.initial);
  late final PageController _pageController = PageController(initialPage: _page);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    _pageController.animateToPage(page, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        elevation: 0,
        leading: IconButton(icon: Icon(Icons.close, color: tokens.ink), onPressed: () => Navigator.of(context).pop()),
        title: Text(_tabLabels[_page][0] + _tabLabels[_page].substring(1).toLowerCase(), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _page = i),
              children: const [
                _CameraStoryPage(),
                _TextStoryPage(),
                _PollFormPage(),
                _PlaceFormPage(),
              ],
            ),
          ),
          _BottomLabelBar(page: _page, onSelect: _goTo),
        ],
      ),
    );
  }
}

class _BottomLabelBar extends StatelessWidget {
  final int page;
  final ValueChanged<int> onSelect;
  const _BottomLabelBar({required this.page, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      decoration: BoxDecoration(color: tokens.surface, border: Border(top: BorderSide(color: tokens.line))),
      child: SafeArea(
        top: false,
        child: Row(
          children: List.generate(_tabLabels.length, (i) {
            final active = i == page;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _tabLabels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: active ? tokens.brand : tokens.mute,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Page 0 — the camera tab. Live preview + shutter first; once something's
/// captured, this same page turns into a caption/post-to/anon review
/// (same shape as the other three tabs' forms) so posting a camera Story
/// never has to leave this screen.
class _CameraStoryPage extends StatefulWidget {
  const _CameraStoryPage();

  @override
  State<_CameraStoryPage> createState() => _CameraStoryPageState();
}

class _CameraStoryPageState extends State<_CameraStoryPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _ready = false;
  String? _error;

  bool _isRecording = false;
  DateTime? _recordStart;
  double _recordProgress = 0;
  Timer? _recordTicker;
  bool _busy = false;

  File? _mediaFile;
  bool _isVideo = false;
  VideoPlayerController? _videoController;

  final _captionController = TextEditingController();
  bool _anon = false;
  String _place = 'main';

  late final AnimationController _partyController =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  bool get _reviewing => _mediaFile != null;

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
        if (mounted) setState(() => _error = 'No camera found on this device.');
        return;
      }
      _cameras = cameras;
      _cameraIndex = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _openCamera(_cameraIndex);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the camera: $e');
    }
  }

  Future<void> _openCamera(int index) async {
    final previous = _controller;
    _controller = null;
    if (mounted) setState(() => _ready = false);
    await previous?.dispose();

    final controller = CameraController(_cameras[index], ResolutionPreset.high, enableAudio: true);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraIndex = index;
        _ready = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the camera: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      controller.dispose();
      _controller = null;
      setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed && !_reviewing) {
      _openCamera(_cameraIndex);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTicker?.cancel();
    _partyController.dispose();
    _controller?.dispose();
    _videoController?.dispose();
    _captionController.dispose();
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
      setState(() {
        _mediaFile = savedFile;
        _isVideo = false;
        _busy = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = 'Could not take the photo: $e';
        _busy = false;
      });
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
      final videoController = VideoPlayerController.file(savedFile);
      await videoController.initialize();
      await videoController.setLooping(true);
      await videoController.setVolume(0);
      await videoController.play();
      if (!mounted) {
        videoController.dispose();
        return;
      }
      setState(() {
        _mediaFile = savedFile;
        _isVideo = true;
        _videoController = videoController;
        _busy = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = 'Could not save the video: $e';
        _busy = false;
      });
    }
  }

  void _cancelRecording() {
    if (_isRecording) _stopRecording();
  }

  void _flipCamera() {
    if (_cameras.length < 2 || _busy || _isRecording) return;
    _openCamera((_cameraIndex + 1) % _cameras.length);
  }

  void _retake() {
    _videoController?.dispose();
    _videoController = null;
    setState(() {
      _mediaFile = null;
      _isVideo = false;
      _captionController.clear();
    });
  }

  void _post(AppStore store) {
    final caption = _captionController.text.trim();
    store.addStory(
      text: caption.isEmpty ? null : caption,
      imagePath: _isVideo ? null : _mediaFile!.path,
      videoPath: _isVideo ? _mediaFile!.path : null,
      place: _place,
      anon: _anon,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    return _reviewing ? _buildReview(context, tokens, store) : _buildCamera(context, tokens);
  }

  Widget _buildCamera(BuildContext context, ThemeTokens tokens) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready && _controller != null)
            Center(child: CameraPreview(_controller!))
          else
            Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),

          // "Party mode" — a cycling rainbow glow traced around the edge of
          // the camera area while recording, like lights flashing around
          // the frame.
          if (_isRecording)
            AnimatedBuilder(
              animation: _partyController,
              builder: (context, _) => IgnorePointer(
                child: CustomPaint(painter: _PartyBorderPainter(_partyController.value), size: Size.infinite),
              ),
            ),

          Positioned(
            top: 8,
            right: 8,
            child: Row(
              children: [
                if (_isRecording)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                    child: Text('${(_recordProgress * 15).toStringAsFixed(0)}s / 15s', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                _RoundIconButton(icon: Icons.flip_camera_ios, onTap: _isRecording ? null : _flipCamera),
              ],
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isRecording)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text('Tap for a photo · Hold for a video', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                  ),
                GestureDetector(
                  onTap: _takePhoto,
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _cancelRecording(),
                  onLongPressCancel: _cancelRecording,
                  child: AnimatedBuilder(
                    animation: _partyController,
                    builder: (context, _) => CustomPaint(
                      size: const Size(84, 84),
                      painter: _CaptureButtonPainter(progress: _recordProgress, recording: _isRecording, partyT: _partyController.value),
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

  Widget _buildReview(BuildContext context, ThemeTokens tokens, AppStore store) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 280,
                  child: _isVideo && _videoController != null && _videoController!.value.isInitialized
                      ? FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _videoController!.value.size.width,
                            height: _videoController!.value.size.height,
                            child: VideoPlayer(_videoController!),
                          ),
                        )
                      : Image.file(_mediaFile!, fit: BoxFit.cover),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: InkWell(
                    onTap: _retake,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close, color: Colors.white, size: 18),
                    ),
                  ),
                ),
                if (_isVideo) const Positioned(left: 8, bottom: 8, child: _VideoBadge()),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _captionController,
            maxLength: 200,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: 'Add a caption (optional)',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 10),
          Text('Post to', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FunkyChip(label: 'Area', active: _place == 'main', onPressed: () => setState(() => _place = 'main')),
              ...store.rankedPlaces.take(6).map((p) => FunkyChip(label: p.name, active: _place == p.id, onPressed: () => setState(() => _place = p.id))),
            ],
          ),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () => setState(() => _anon = !_anon),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    border: Border.all(color: tokens.line, width: 1.5),
                    borderRadius: BorderRadius.circular(5),
                    color: _anon ? tokens.brand : Colors.transparent,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Post anonymously', style: TextStyle(color: tokens.ink)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _retake,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: tokens.ink,
                    side: BorderSide(color: tokens.line),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Retake', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => requireAccountThen(context, store, () => _post(store)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Post Story', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
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
        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: Icon(icon, color: onTap == null ? Colors.white38 : Colors.white),
      ),
    );
  }
}

/// A rainbow sweep traced around the capture button. At rest it's a plain
/// white ring. While recording, a red progress arc tracks the 15s cap and
/// a blurred, continuously rotating rainbow halo pulses behind it — the
/// "party mode" effect, like a Juul flashing colors when shaken.
class _CaptureButtonPainter extends CustomPainter {
  final double progress;
  final bool recording;
  final double partyT;

  _CaptureButtonPainter({required this.progress, required this.recording, required this.partyT});

  Color _hue(double base) => HSVColor.fromAHSV(1, (base * 360) % 360, 0.9, 1).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outerRadius = size.width / 2;

    if (recording) {
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      final colors = List.generate(7, (i) => _hue(partyT + i / 6));
      glowPaint.shader = SweepGradient(colors: colors, transform: GradientRotation(partyT * 6.28318))
          .createShader(Rect.fromCircle(center: center, radius: outerRadius + 6));
      canvas.drawCircle(center, outerRadius + 2, glowPaint);
    }

    final fillPaint = Paint()..color = recording ? const Color(0xFFE53935) : Colors.white;
    canvas.drawCircle(center, outerRadius - 10, fillPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white;
    canvas.drawCircle(center, outerRadius - 4, ringPaint);

    if (recording) {
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

/// The screen-edge version of the same rainbow party-mode effect.
class _PartyBorderPainter extends CustomPainter {
  final double t;
  _PartyBorderPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final colors = List.generate(7, (i) => HSVColor.fromAHSV(1, ((t + i / 6) * 360) % 360, 0.95, 1).toColor());
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..shader = SweepGradient(colors: colors, transform: GradientRotation(t * 6.28318)).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _PartyBorderPainter oldDelegate) => oldDelegate.t != t;
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text('Video', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Page 1 — a text-only Story. Media Stories go through the camera tab
/// instead; this one is just the caption.
class _TextStoryPage extends StatefulWidget {
  const _TextStoryPage();

  @override
  State<_TextStoryPage> createState() => _TextStoryPageState();
}

class _TextStoryPageState extends State<_TextStoryPage> {
  final _textController = TextEditingController();
  bool _anon = false;
  String _place = 'main';

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final canPost = _textController.text.trim().isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _textController,
            maxLength: 200,
            maxLines: 4,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: "What's happening?",
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 10),
          Text('Post to', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FunkyChip(label: 'Area', active: _place == 'main', onPressed: () => setState(() => _place = 'main')),
              ...store.rankedPlaces.take(6).map((p) => FunkyChip(label: p.name, active: _place == p.id, onPressed: () => setState(() => _place = p.id))),
            ],
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () => setState(() => _anon = !_anon),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    border: Border.all(color: tokens.line, width: 1.5),
                    borderRadius: BorderRadius.circular(5),
                    color: _anon ? tokens.brand : Colors.transparent,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Post anonymously', style: TextStyle(color: tokens.ink)),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: canPost
                  ? () => requireAccountThen(context, store, () {
                        store.addStory(text: _textController.text.trim(), place: _place, anon: _anon);
                        Navigator.of(context).pop();
                      })
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Post Story', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 2 — ask a poll.
class _PollFormPage extends StatefulWidget {
  const _PollFormPage();

  @override
  State<_PollFormPage> createState() => _PollFormPageState();
}

class _PollFormPageState extends State<_PollFormPage> {
  final _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _questionController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final filledOptions = _optionControllers.where((c) => c.text.trim().isNotEmpty).length;
    final canPost = _questionController.text.trim().isNotEmpty && filledOptions >= 2;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Question', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(
            controller: _questionController,
            maxLength: 80,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Best bar tonight?',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 10),
          Text('Options', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          ...List.generate(_optionControllers.length, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _optionControllers[i],
                maxLength: 40,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Option ${i + 1}',
                  hintStyle: TextStyle(color: tokens.mute),
                  filled: true,
                  fillColor: tokens.raised,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
                style: TextStyle(color: tokens.ink),
              ),
            );
          }),
          if (_optionControllers.length < 8)
            TextButton(
              onPressed: () => setState(() => _optionControllers.add(TextEditingController())),
              child: Text('+ Add option', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: canPost
                  ? () => requireAccountThen(context, store, () {
                        final options = _optionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
                        store.addPoll(_questionController.text.trim(), options);
                        Navigator.of(context).pop();
                      })
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Post poll', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

const _placeKinds = [
  (PlaceKind.frat, 'Fraternity'),
  (PlaceKind.party, 'Party'),
  (PlaceKind.bar, 'Bar'),
  (PlaceKind.club, 'Club'),
  (PlaceKind.event, 'Event'),
  (PlaceKind.tailgate, 'Tailgate'),
];

/// Page 3 — add a place.
class _PlaceFormPage extends StatefulWidget {
  const _PlaceFormPage();

  @override
  State<_PlaceFormPage> createState() => _PlaceFormPageState();
}

class _PlaceFormPageState extends State<_PlaceFormPage> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  PlaceKind _kind = PlaceKind.party;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final canPost = _nameController.text.trim().isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Name', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(
            controller: _nameController,
            maxLength: 40,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Taverns Bar',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 14),
          Text('Type', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _placeKinds.map((k) => FunkyChip(label: k.$2, active: _kind == k.$1, onPressed: () => setState(() => _kind = k.$1))).toList(),
          ),
          const SizedBox(height: 14),
          Text('Address', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(
            controller: _addressController,
            decoration: InputDecoration(
              hintText: 'Street address',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 6),
          Text(
            store.locationStatus == LocationStatus.granted
                ? 'The pin drops at your current location — address lookup is a near-term follow-up (see HANDOFF.md).'
                : 'Enable location first so this place can be placed on the map.',
            style: TextStyle(color: tokens.mute, fontSize: 12),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: canPost
                  ? () => requireAccountThen(context, store, () {
                        final place = store.addPlace(
                          _nameController.text.trim(),
                          _kind,
                          _addressController.text.trim().isEmpty ? 'Address not given' : _addressController.text.trim(),
                        );
                        Navigator.of(context).pop();
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: place.id)));
                      })
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Add place', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}
