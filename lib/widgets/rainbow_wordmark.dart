import 'package:flutter/material.dart';

/// The FUNKY wordmark with its orange letters cycling through the rainbow,
/// scrolling from right to left like the old animated clan tags. The white
/// outline stays white: the logo's silhouette is drawn white, then a rainbow
/// gradient is painted through a mask of just the orange letter fill
/// (assets/branding/funky_wordmark_fill.png).
///
/// Falls back to the plain still logo when the phone has "reduce motion" on.
class RainbowWordmark extends StatefulWidget {
  final double height;
  const RainbowWordmark({super.key, this.height = 38});

  @override
  State<RainbowWordmark> createState() => _RainbowWordmarkState();
}

class _RainbowWordmarkState extends State<RainbowWordmark> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat();

  static const _rainbow = <Color>[
    Color(0xFFFF2D2D), // red
    Color(0xFFFF8A00), // orange
    Color(0xFFFFE600), // yellow
    Color(0xFF22E64A), // green
    Color(0xFF00E5FF), // cyan
    Color(0xFF2D5BFF), // blue
    Color(0xFFB026FF), // violet
    Color(0xFFFF2DAA), // pink
    Color(0xFFFF2D2D), // back to red so the loop has no seam
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const asset = 'assets/branding/funky_wordmark.png';
    final still = Image.asset(asset, height: widget.height, fit: BoxFit.contain, alignment: Alignment.centerLeft);
    if (MediaQuery.of(context).disableAnimations) return still;

    return RepaintBoundary(
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // White silhouette of the whole logo (outline + letters).
          ColorFiltered(
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
            child: still,
          ),
          // Rainbow, only where the orange letters are.
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => LinearGradient(
                colors: _rainbow,
                tileMode: TileMode.repeated,
                transform: _SlideGradient(_controller.value),
              ).createShader(bounds),
              child: child,
            ),
            child: Image.asset(
              'assets/branding/funky_wordmark_fill.png',
              height: widget.height,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      ),
    );
  }
}

/// Slides the gradient one full width to the left per loop (right-to-left).
class _SlideGradient extends GradientTransform {
  final double t;
  const _SlideGradient(this.t);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(-bounds.width * t, 0, 0);
}
