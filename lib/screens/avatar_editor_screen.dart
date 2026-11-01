import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/avatar_presets.dart';
import '../widgets/ui_widgets.dart';

/// The looks you can put on a profile picture.
class _Look {
  final String name;
  final List<double>? matrix; // 4x5 color matrix, null = as is
  const _Look(this.name, this.matrix);
}

List<double> _saturation(double s) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final sr = (1 - s) * r, sg = (1 - s) * g, sb = (1 - s) * b;
  return [sr + s, sg, sb, 0, 0, sr, sg + s, sb, 0, 0, sr, sg, sb + s, 0, 0, 0, 0, 0, 1, 0];
}

final _looks = <_Look>[
  const _Look('Original', null),
  _Look('B&W', _saturation(0)),
  const _Look('Warm', [1.12, 0, 0, 0, 8, 0, 1.02, 0, 0, 2, 0, 0, 0.88, 0, -6, 0, 0, 0, 1, 0]),
  const _Look('Cool', [0.9, 0, 0, 0, -6, 0, 1.0, 0, 0, 2, 0, 0, 1.12, 0, 10, 0, 0, 0, 1, 0]),
  _Look('Vivid', _saturation(1.45)),
  const _Look('Fade', [0.85, 0, 0, 0, 28, 0, 0.85, 0, 0, 28, 0, 0, 0.85, 0, 28, 0, 0, 0, 1, 0]),
];

/// The chosen look with [brightness] (-1..1) added on.
List<double> _matrixFor(int look, double brightness) {
  final base = List<double>.from(_looks[look].matrix ?? const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
  final add = brightness * 60;
  base[4] += add;
  base[9] += add;
  base[14] += add;
  return base;
}

/// Crop and touch up a new profile picture: drag and pinch to frame it in
/// the circle, rotate, pick a look, brighten. Returns the saved picture's
/// path (a square PNG), or null if cancelled.
class AvatarEditorScreen extends StatefulWidget {
  final String path;
  const AvatarEditorScreen({super.key, required this.path});

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  ui.Image? _image;
  String? _error;
  double _scale = 1;
  Offset _offset = Offset.zero;
  int _quarter = 0; // quarter turns clockwise
  int _look = 0;
  double _brightness = 0;
  bool _saving = false;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600, allowUpscaling: false);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't open that picture.");
    }
  }

  /// Width and height after rotating.
  Size _turnedSize(ui.Image img) =>
      _quarter.isOdd ? Size(img.height.toDouble(), img.width.toDouble()) : Size(img.width.toDouble(), img.height.toDouble());

  /// The scale at which the picture just fills the [side]-wide square.
  double _coverScale(ui.Image img, double side) {
    final s = _turnedSize(img);
    return side / math.min(s.width, s.height);
  }

  Offset _clampOffset(Offset o, ui.Image img, double side) {
    final k = _coverScale(img, side) * _scale;
    final s = _turnedSize(img);
    final maxX = math.max(0.0, (s.width * k - side) / 2);
    final maxY = math.max(0.0, (s.height * k - side) / 2);
    return Offset(o.dx.clamp(-maxX, maxX), o.dy.clamp(-maxY, maxY));
  }

  Future<void> _save(double side) async {
    final img = _image;
    if (img == null || _saving) return;
    setState(() => _saving = true);
    try {
      const out = 640.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, out, out));
      canvas.scale(out / side);
      _AvatarPainter(image: img, side: side, scale: _coverScale(img, side) * _scale, offset: _offset, quarter: _quarter, matrix: _matrixFor(_look, _brightness))
          .paintPicture(canvas);
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(out.toInt(), out.toInt());
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      rendered.dispose();
      if (data == null) throw const FormatException('no image data');
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/stories');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save that picture: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final img = _image;
    final side = math.min(MediaQuery.of(context).size.width - 32, 380.0);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white)),
        ),
        leadingWidth: 84,
        title: const Text('Edit photo'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: img == null || _saving ? null : () => _save(side),
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text('Done', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ],
      ),
      body: SafeArea(
        child: img == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: const TextStyle(color: Colors.white70))
                    : const CircularProgressIndicator(color: Colors.white),
              )
            : Column(
                children: [
                  const SizedBox(height: 18),
                  const Text('Drag and pinch to fit it in the circle', style: TextStyle(color: Colors.white60, fontSize: 13)),
                  const SizedBox(height: 14),
                  Center(
                    child: GestureDetector(
                      onScaleStart: (d) {
                        _startScale = _scale;
                        _startOffset = _offset;
                        _startFocal = d.focalPoint;
                      },
                      onScaleUpdate: (d) {
                        setState(() {
                          _scale = (_startScale * d.scale).clamp(1.0, 6.0);
                          _offset = _clampOffset(_startOffset + (d.focalPoint - _startFocal), img, side);
                        });
                      },
                      onDoubleTap: () => setState(() {
                        _scale = 1;
                        _offset = Offset.zero;
                      }),
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: CustomPaint(
                          painter: _AvatarPainter(
                            image: img,
                            side: side,
                            scale: _coverScale(img, side) * _scale,
                            offset: _offset,
                            quarter: _quarter,
                            matrix: _matrixFor(_look, _brightness),
                            showMask: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ToolButton(
                        icon: Icons.rotate_right_rounded,
                        label: 'Rotate',
                        onTap: () => setState(() {
                          _quarter = (_quarter + 1) % 4;
                          _offset = _clampOffset(_offset, img, side);
                        }),
                      ),
                      const SizedBox(width: 18),
                      _ToolButton(
                        icon: Icons.restart_alt_rounded,
                        label: 'Reset',
                        onTap: () => setState(() {
                          _scale = 1;
                          _offset = Offset.zero;
                          _quarter = 0;
                          _look = 0;
                          _brightness = 0;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _looks.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final active = i == _look;
                        return GestureDetector(
                          onTap: () => setState(() => _look = i),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: active ? tokens.orange : Colors.white12,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(_looks[i].name, style: TextStyle(color: Colors.white, fontWeight: active ? FontWeight.w800 : FontWeight.w600)),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Row(
                      children: [
                        const Icon(Icons.brightness_low_rounded, color: Colors.white60, size: 20),
                        Expanded(
                          child: Slider(
                            value: _brightness,
                            min: -1,
                            max: 1,
                            activeColor: tokens.orange,
                            onChanged: (v) => setState(() => _brightness = v),
                          ),
                        ),
                        const Icon(Icons.brightness_high_rounded, color: Colors.white60, size: 20),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 19),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// Draws the picture framed in the square (and, on screen, darkens what
/// falls outside the circle).
class _AvatarPainter extends CustomPainter {
  final ui.Image image;
  final double side;
  final double scale;
  final Offset offset;
  final int quarter;
  final List<double> matrix;
  final bool showMask;
  _AvatarPainter({
    required this.image,
    required this.side,
    required this.scale,
    required this.offset,
    required this.quarter,
    required this.matrix,
    this.showMask = false,
  });

  void paintPicture(Canvas canvas) {
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, side, side));
    canvas.drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = Colors.black);
    canvas.translate(side / 2 + offset.dx, side / 2 + offset.dy);
    canvas.rotate(quarter * math.pi / 2);
    canvas.scale(scale);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..colorFilter = ColorFilter.matrix(matrix);
    canvas.drawImage(image, Offset(-image.width / 2, -image.height / 2), paint);
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    paintPicture(canvas);
    if (!showMask) return;
    final full = Path()..addRect(Rect.fromLTWH(0, 0, side, side));
    final circle = Path()..addOval(Rect.fromLTWH(0, 0, side, side));
    canvas.drawPath(Path.combine(PathOperation.difference, full, circle), Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawOval(
      Rect.fromLTWH(1, 1, side - 2, side - 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_AvatarPainter old) =>
      old.image != image || old.scale != scale || old.offset != offset || old.quarter != quarter || old.matrix != matrix || old.side != side;
}

/// A grid of FUNKY's own avatars to pick from.
Future<void> showAvatarPresetPicker(BuildContext context) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final store = context.read<AppStore>();
  final picked = await showModalBottomSheet<AvatarPreset>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pick a FUNKY avatar', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              children: [
                for (final p in avatarPresets)
                  GestureDetector(
                    onTap: () => Navigator.of(sheetContext).pop(p),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: store.me.photoUrl == p.value ? tokens.orange : Colors.transparent, width: 3),
                      ),
                      child: ClipOval(child: Image.asset(p.asset, fit: BoxFit.cover)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final err = await store.setAvatarPreset(picked.value);
  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
}
