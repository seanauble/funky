import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// A cover photo or flyer shown whole — its own shape, not cropped into a
/// banner. Very tall or very wide pictures are fit inside a blurred copy of
/// themselves so the edges still show.
class FullArtImage extends StatefulWidget {
  final String? filePath;
  final String? url;
  final double radius;
  final double minAspect; // width / height
  final double maxAspect;
  final Widget? fallback;
  const FullArtImage({
    super.key,
    this.filePath,
    this.url,
    this.radius = 14,
    this.minAspect = 0.62,
    this.maxAspect = 1.9,
    this.fallback,
  });

  bool get hasImage => (filePath != null && filePath!.isNotEmpty) || (url != null && url!.isNotEmpty);

  @override
  State<FullArtImage> createState() => _FullArtImageState();
}

class _FullArtImageState extends State<FullArtImage> {
  double? _aspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _failed = false;

  ImageProvider? get _provider {
    final path = widget.filePath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) return FileImage(File(path));
    final url = widget.url;
    if (url != null && url.isNotEmpty) return NetworkImage(url);
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FullArtImage old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath || old.url != widget.url) {
      _aspect = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final provider = _provider;
    _detach();
    if (provider == null) return;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (mounted && h > 0) setState(() => _aspect = w / h);
      },
      onError: (_, __) {
        if (mounted) setState(() => _failed = true);
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detach() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null || _failed) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: AspectRatio(aspectRatio: 16 / 9, child: widget.fallback ?? const ColoredBox(color: Colors.black12)),
      );
    }
    final natural = _aspect ?? 1.0;
    final shown = natural.clamp(widget.minAspect, widget.maxAspect);
    final squeezed = (natural - shown).abs() > 0.01;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        child: AspectRatio(
          aspectRatio: shown,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (squeezed)
                ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Image(image: provider, fit: BoxFit.cover),
                ),
              Image(
                image: provider,
                fit: squeezed ? BoxFit.contain : BoxFit.cover,
                frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                  opacity: frame == null && !sync ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
