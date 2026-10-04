import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../theme/colors.dart';
import '../data/models.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
        ],
      ),
    );
  }
}

class FunkyChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onPressed;
  const FunkyChip({super.key, required this.label, this.active = false, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active ? tokens.brand : tokens.raised,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: active ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
    );
  }
}

class FunkyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  const FunkyCard({super.key, required this.child, this.padding, this.margin});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: TextStyle(color: tokens.mute)),
    );
  }
}

class FootNote extends StatelessWidget {
  final String text;
  const FootNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: tokens.line))),
      child: Text(text, style: TextStyle(color: tokens.mute, fontSize: 13)),
    );
  }
}

class FunkyAvatar extends StatelessWidget {
  final String seed;
  final String label;
  final double size;
  // A profile photo taken with the in-app camera (Person.photoPath) — when
  // set, this is shown instead of the colored-initial circle. Null (the
  // common case for everyone but 'me' right now, and for 'me' before ever
  // setting one) falls back to the initial.
  final String? photoPath;
  const FunkyAvatar({super.key, required this.seed, required this.label, this.size = 40, this.photoPath});

  @override
  Widget build(BuildContext context) {
    final color = hueOf(seed);
    final letter = label.isNotEmpty ? label.substring(0, 1).toUpperCase() : '?';
    final path = photoPath;
    if (path != null) {
      return ClipOval(
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // Falls back to the initial circle if the file's gone missing
          // (e.g. the OS cleared app storage) instead of a broken-image icon.
          errorBuilder: (_, __, ___) => _initialCircle(color, letter),
        ),
      );
    }
    return _initialCircle(color, letter);
  }

  Widget _initialCircle(Color color, String letter) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Text(letter, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.4)),
      );
}

/// Renders a person's handle/name with whichever point-unlocked cosmetic
/// styles they've turned on — bold (500 pts), italic (1000), underline
/// (2000), and a trailing checkmark badge (5000). Every unlocked style
/// that's switched on applies at the same time (see Person.nameBold etc
/// and AppStore.setNameStyle/canUseBoldName in models.dart), not just one.
/// Still gated by [canUseBoldName] etc here too, so a style that was turned
/// on before points ever dropped (they currently never do, but just in
/// case) can't render a style that isn't actually unlocked.
class StyledName extends StatelessWidget {
  final Person person;
  final String text;
  final TextStyle style;
  const StyledName({super.key, required this.person, required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    var effective = style;
    if (person.nameBold && canUseBoldName(person.points)) {
      effective = effective.copyWith(fontWeight: FontWeight.w900);
    }
    if (person.nameItalic && canUseItalicName(person.points)) {
      effective = effective.copyWith(fontStyle: FontStyle.italic);
    }
    if (person.nameUnderline && canUseUnderlineName(person.points)) {
      effective = effective.copyWith(decoration: TextDecoration.underline);
    }
    final showCheck = person.nameCheckbox && canUseCheckName(person.points);
    if (!showCheck) return Text(text, style: effective);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(text, style: effective, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 3),
        Icon(Icons.check_box, size: (effective.fontSize ?? 14) * 0.85, color: effective.color ?? Colors.white),
      ],
    );
  }
}

/// What a place's thumbnail/banner shows: the newest Story posted there
/// that actually has a photo or video, looping and muted if it's a video —
/// falling back to whoever added the place's own cover photo (if they took
/// one) when nothing's been posted yet, and only then to the flat
/// colored-letter box. Used anywhere a place shows a preview image: the
/// Place Detail banner, Home's trending cards, and the Places list.
class PlaceMediaThumbnail extends StatefulWidget {
  final Story? story;
  final String? coverPhotoPath;
  final String fallbackLabel;
  final double fontSize;
  const PlaceMediaThumbnail({super.key, required this.story, this.coverPhotoPath, required this.fallbackLabel, this.fontSize = 22});

  @override
  State<PlaceMediaThumbnail> createState() => _PlaceMediaThumbnailState();
}

class _PlaceMediaThumbnailState extends State<PlaceMediaThumbnail> {
  VideoPlayerController? _controller;
  String? _controllerForPath;

  @override
  void initState() {
    super.initState();
    _ensureController();
  }

  @override
  void didUpdateWidget(PlaceMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
  }

  void _ensureController() {
    // A local file (your own just-captured Story) takes priority; a remote
    // signed URL (someone else's real-backend Story) is the fallback —
    // see Story.videoUrl's doc comment in models.dart.
    final path = widget.story?.videoPath;
    final url = widget.story?.videoUrl;
    final key = path ?? url;
    if (key == null) {
      final old = _controller;
      _controller = null;
      _controllerForPath = null;
      old?.dispose();
      return;
    }
    if (_controllerForPath == key) return;
    _controllerForPath = key;
    final old = _controller;
    _controller = null;
    old?.dispose();
    final c = path != null ? VideoPlayerController.file(File(path)) : VideoPlayerController.networkUrl(Uri.parse(url!));
    c.setLooping(true);
    c.setVolume(0);
    c.initialize().then((_) {
      if (!mounted) return;
      c.play();
      setState(() {});
    });
    _controller = c;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final story = widget.story;
    final controller = _controller;
    if ((story?.videoPath != null || story?.videoUrl != null) && controller != null && controller.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      );
    }
    if (story?.imagePath != null) {
      return Image.file(
        File(story!.imagePath!),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _fallback(tokens),
      );
    }
    if (story?.imageUrl != null) {
      return Image.network(
        story!.imageUrl!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _fallback(tokens),
      );
    }
    final cover = widget.coverPhotoPath;
    if (cover != null) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _fallback(tokens),
      );
    }
    return _fallback(tokens);
  }

  Widget _fallback(ThemeTokens tokens) => Container(
        color: tokens.raised,
        alignment: Alignment.center,
        child: Text(widget.fallbackLabel, style: TextStyle(fontSize: widget.fontSize, fontWeight: FontWeight.w800, color: tokens.mute)),
      );
}

/// A single static frame from a video — used for grid thumbnails (the
/// Memories grid on Profile) where an always-looping autoplay video like
/// PlaceMediaThumbnail would be overkill, and a real battery/perf hit once
/// there's a whole grid of them on screen at once. Initializes the video
/// just far enough to decode a real frame and then stays paused on it —
/// seeking to literal position zero renders solid black on a lot of
/// encoders (the very first frame is often not a real keyframe), so this
/// seeks a little past zero instead. Works for either a local file (your
/// own capture) or a remote signed URL (a Memory synced from another
/// device — see Story.videoUrl's doc comment in models.dart).
class VideoFrameThumbnail extends StatefulWidget {
  final String? path;
  final String? url;
  final BoxFit fit;
  const VideoFrameThumbnail({super.key, this.path, this.url, this.fit = BoxFit.cover}) : assert(path != null || url != null);

  @override
  State<VideoFrameThumbnail> createState() => _VideoFrameThumbnailState();
}

class _VideoFrameThumbnailState extends State<VideoFrameThumbnail> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VideoFrameThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.url != widget.url) {
      final old = _controller;
      _controller = null;
      _ready = false;
      _failed = false;
      old?.dispose();
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.path;
    final url = widget.url;
    final c = path != null ? VideoPlayerController.file(File(path)) : VideoPlayerController.networkUrl(Uri.parse(url!));
    _controller = c;
    try {
      await c.initialize();
      await c.seekTo(const Duration(milliseconds: 200));
      if (!mounted || _controller != c) return;
      setState(() => _ready = true);
    } catch (_) {
      if (!mounted || _controller != c) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final controller = _controller;
    if (_failed || controller == null) {
      return Container(color: tokens.raised, alignment: Alignment.center, child: Icon(Icons.videocam_off_outlined, color: tokens.mute));
    }
    if (!_ready || !controller.value.isInitialized) {
      return Container(
        color: tokens.raised,
        alignment: Alignment.center,
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.mute)),
      );
    }
    return FittedBox(
      fit: widget.fit,
      child: SizedBox(width: controller.value.size.width, height: controller.value.size.height, child: VideoPlayer(controller)),
    );
  }
}

/// One swipeable camera filter — a plain Flutter ColorFilter matrix, no
/// extra image-processing package needed. `matrix == null` is "Normal"
/// (no filter at all), which both camera screens treat as a reason to
/// skip wrapping the preview in ColorFiltered entirely, so the common
/// case costs nothing extra to paint.
class CameraFilter {
  final String name;
  final List<double>? matrix;
  const CameraFilter(this.name, this.matrix);
  ColorFilter? get colorFilter => matrix == null ? null : ColorFilter.matrix(matrix!);
}

/// Swipe left/right on the camera preview to cycle through these — see
/// _onZoomUpdate in create_flow_screen.dart/camera_capture_screen.dart for
/// the gesture, which reuses the existing pinch-to-zoom GestureDetector
/// rather than adding a second, competing one (a single-finger drag there
/// was already effectively a no-op for zoom, since ScaleGestureDetector
/// only reports a real `scale` once a second finger joins).
const List<CameraFilter> cameraFilters = [
  CameraFilter('Normal', null),
  CameraFilter('B&W', [
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Warm', [
    1.15, 0, 0, 0, 10, //
    0, 1.05, 0, 0, 5, //
    0, 0, 0.85, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Cool', [
    0.9, 0, 0, 0, 0, //
    0, 1.0, 0, 0, 0, //
    0, 0, 1.2, 0, 10, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Vivid', [
    1.315, -0.286, -0.029, 0, 0, //
    -0.085, 1.114, -0.029, 0, 0, //
    -0.085, -0.286, 1.371, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Vintage', [
    0.764, 0.215, 0.022, 0, 15, //
    0.064, 0.915, 0.022, 0, 8, //
    0.064, 0.215, 0.722, 0, -10, //
    0, 0, 0, 1, 0,
  ]),
];

/// Re-encodes a captured photo's bytes with [filter] baked in permanently
/// — needed because the live preview's ColorFiltered only ever affects
/// what's on screen, never the camera plugin's own saved file. Pure
/// dart:ui (decode → redraw through a Paint with the same ColorFilter →
/// re-encode), no image-processing package. Returns [bytes] unchanged if
/// [filter] is Normal. The output is always PNG regardless of the input
/// format — dart:ui can only re-encode to PNG, not JPEG — so callers
/// should save it with a .png extension to match.
Future<Uint8List> applyCameraFilterToImageBytes(Uint8List bytes, CameraFilter filter) async {
  final cf = filter.colorFilter;
  if (cf == null) return bytes;
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint()..colorFilter = cf);
    final picture = recorder.endRecording();
    final outputImage = await picture.toImage(image.width, image.height);
    try {
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return bytes;
      return byteData.buffer.asUint8List();
    } finally {
      outputImage.dispose();
    }
  } finally {
    image.dispose();
  }
}

class FunkyHandle extends StatelessWidget {
  final String handle;
  // Optional — when the full Person is on hand, their point-unlocked
  // cosmetic name styling (bold/italic/underline/checkmark, see
  // StyledName) renders too. Callers that only have a bare handle string
  // (no Person loaded) just get the plain colored handle, same as before.
  final Person? person;
  const FunkyHandle({super.key, required this.handle, this.person});

  @override
  Widget build(BuildContext context) {
    final color = hueOf(handle);
    final style = TextStyle(color: color, fontWeight: FontWeight.w700);
    final p = person;
    if (p == null) return Text('@$handle', style: style);
    return StyledName(person: p, text: '@$handle', style: style);
  }
}

/// One heading + paragraph pair on an InfoScreen (Privacy Policy, Terms,
/// About — anything that's just static text in Settings).
class InfoSection {
  final String heading;
  final String body;
  const InfoSection(this.heading, this.body);
}

/// A plain scrollable title + sections page, shared by the static Settings
/// screens (Privacy Policy, Terms & Conditions, About) so they all look and
/// scroll the same way.
class InfoScreen extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<InfoSection> sections;
  const InfoScreen({super.key, required this.title, this.subtitle, required this.sections});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (subtitle != null) ...[
            Text(subtitle!, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
            const SizedBox(height: 18),
          ],
          for (final s in sections) ...[
            Text(s.heading, style: TextStyle(color: tokens.ink, fontSize: 15.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(s.body, style: TextStyle(color: tokens.mute, fontSize: 14, height: 1.45)),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}

/// A ThemeExtension wrapper so every widget can reach FUNKY's own color
/// tokens (ported straight from the prototype's CSS) through the normal
/// Theme.of(context) lookup, instead of plumbing them through as params.
class FunkyTokens extends ThemeExtension<FunkyTokens> {
  final ThemeTokens tokens;
  const FunkyTokens(this.tokens);

  @override
  FunkyTokens copyWith({ThemeTokens? tokens}) => FunkyTokens(tokens ?? this.tokens);

  @override
  FunkyTokens lerp(ThemeExtension<FunkyTokens>? other, double t) => this;
}

// --- Content filtering ---------------------------------------------------
// Slurs get blurred out wherever a message's own text is shown (area chat,
// DMs) — tap a blurred word to reveal it, the same "sensitive content"
// pattern used elsewhere. Ordinary cursing is left alone on purpose; this
// list is specifically slurs (racial, homophobic/transphobic, ableist),
// not profanity in general, and it deliberately leaves out plain identity
// words that AREN'T slurs (gay, lesbian, trans, etc) — blurring those out
// would be wrong, not safer. Not exhaustive — no client-side word list
// ever catches every spelling/leetspeak dodge — just a reasonable first
// line of defense; deleteMessage (Admin) still exists for anything this
// misses.
const _blurredWords = [
  'nigger', 'nigga', 'niggers', 'niggas',
  'faggot', 'faggots', 'fagot', 'fags',
  'tranny', 'trannies',
  'chink', 'chinks',
  'spic', 'spics',
  'kike', 'kikes',
  'gook', 'gooks',
  'wetback', 'wetbacks',
  'retard', 'retarded',
];

final RegExp _blurredWordPattern = RegExp(
  r'\b(' + _blurredWords.map(RegExp.escape).join('|') + r')\b',
  caseSensitive: false,
);

/// Renders [text] the same as a plain `Text(text, style: style)`, except
/// any slur (see _blurredWords above) is blurred out and only reveals on
/// tap. Use this instead of a bare Text(...) wherever a message's own text
/// is shown — chat bubbles, DMs.
Widget filteredMessageText(String text, TextStyle? style) {
  final matches = _blurredWordPattern.allMatches(text).toList();
  if (matches.isEmpty) return Text(text, style: style);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in matches) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _BlurredWord(word: text.substring(m.start, m.end), style: style),
    ));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return Text.rich(TextSpan(style: style, children: spans));
}

class _BlurredWord extends StatefulWidget {
  final String word;
  final TextStyle? style;
  const _BlurredWord({required this.word, this.style});

  @override
  State<_BlurredWord> createState() => _BlurredWordState();
}

class _BlurredWordState extends State<_BlurredWord> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _revealed = !_revealed),
      child: _revealed
          ? Text(widget.word, style: widget.style)
          : ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 3),
              child: Text(widget.word, style: widget.style),
            ),
    );
  }
}
