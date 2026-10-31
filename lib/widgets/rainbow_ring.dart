import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The ring around a story avatar when there's a Story you haven't watched
/// yet: the same rainbow as the FUNKY logo, spinning around the circle.
/// Holds still when the phone has "reduce motion" on.
class RainbowRing extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Widget child;
  const RainbowRing({super.key, required this.size, required this.child, this.strokeWidth = 3});

  @override
  State<RainbowRing> createState() => _RainbowRingState();
}

class _RainbowRingState extends State<RainbowRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => CustomPaint(
            painter: _RainbowRingPainter(still ? 0 : _controller.value, widget.strokeWidth),
            child: child,
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _RainbowRingPainter extends CustomPainter {
  final double t;
  final double stroke;
  _RainbowRingPainter(this.t, this.stroke);

  static const _rainbow = <Color>[
    Color(0xFFFF2D2D),
    Color(0xFFFF8A00),
    Color(0xFFFFE600),
    Color(0xFF22E64A),
    Color(0xFF00E5FF),
    Color(0xFF2D5BFF),
    Color(0xFFB026FF),
    Color(0xFFFF2DAA),
    Color(0xFFFF2D2D),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = SweepGradient(
        colors: _rainbow,
        // Counter-clockwise spin, like the logo's right-to-left scroll.
        transform: GradientRotation(-2 * math.pi * t),
      ).createShader(rect);
    canvas.drawCircle(rect.center, (size.shortestSide - stroke) / 2, paint);
  }

  @override
  bool shouldRepaint(_RainbowRingPainter old) => old.t != t || old.stroke != stroke;
}
