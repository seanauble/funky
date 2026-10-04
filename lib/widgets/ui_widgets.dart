import 'dart:io';

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
