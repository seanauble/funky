import 'dart:math';

import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';
import 'screens/create_sheet.dart';
import 'screens/home_screen.dart';
import 'screens/places_screen.dart';
import 'screens/profile_screen.dart';
import 'widgets/top_bar_actions.dart';
import 'widgets/ui_widgets.dart';

/// Lets a screen outside RootShell (e.g. Home's "Open chat" shortcut) jump
/// to one of RootShell's own tabs instead of pushing a whole new route on
/// top of it — set this to a tab index and RootShellState's listener below
/// switches to it and immediately resets this back to null. Pushing a
/// standalone ChatScreen used to be what left people stuck with no way
/// back out of chat (it has no AppBar of its own by design, since it's
/// meant to live as a tab); switching the existing tab instead means
/// there's always the normal bottom tab bar to get anywhere else, so no
/// back button is needed on ChatScreen at all.
final ValueNotifier<int?> rootShellTabRequest = ValueNotifier<int?>(null);

/// The five-tab bar from rule 12 — Home, Chat, a centre "+" that opens the
/// Story/Poll/Place sheet, Places, Profile.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    rootShellTabRequest.addListener(_handleTabRequest);
  }

  @override
  void dispose() {
    rootShellTabRequest.removeListener(_handleTabRequest);
    super.dispose();
  }

  void _handleTabRequest() {
    final requested = rootShellTabRequest.value;
    if (requested == null) return;
    setState(() => _index = requested);
    // Reset immediately so a second tap on the same shortcut later still
    // fires the listener (setting a ValueNotifier to its current value is a
    // no-op that never notifies).
    rootShellTabRequest.value = null;
  }

  static const _screens = [
    HomeScreen(),
    ChatScreen(),
    SizedBox.shrink(), // center "+" slot — never actually shown
    PlacesScreen(),
    ProfileScreen(),
  ];

  static const _titles = ['Home', 'Chat', '', 'Places', 'Profile'];

  // A little easter egg: tapping the FUNKY wordmark on Home pops a small
  // confetti burst from right where you tapped. Pure CustomPainter — no
  // new package, same caution as everywhere else in this app.
  void _popConfetti(BuildContext tapContext) {
    final renderBox = tapContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final origin = renderBox.localToGlobal(Offset(renderBox.size.width / 2, renderBox.size.height));
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ConfettiBurst(origin: origin, onDone: () => entry.remove()),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;

    return Scaffold(
      backgroundColor: tokens.bg,
      // Shown on every tab now (Home, Chat, Places, Profile) so the
      // notification bell and settings gear are always reachable, not just
      // from Profile.
      appBar: AppBar(
        backgroundColor: tokens.bg,
        elevation: 0,
        // iOS centers AppBar titles by default, which is why the wordmark
        // looked centered on mobile even with its own centerLeft alignment
        // — force it to the left on every platform, and bump it up a bit
        // so it reads clearly.
        centerTitle: false,
        titleSpacing: 16,
        title: _index == 0
            ? Builder(
                builder: (logoContext) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _popConfetti(logoContext),
                  child: Image.asset(
                    'assets/branding/funky_wordmark.png',
                    height: 38,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                  ),
                ),
              )
            : Text(_titles[_index], style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
        actions: const [NotificationBell(), SettingsGearButton()],
      ),
      body: SafeArea(bottom: false, child: IndexedStack(index: _index, children: _screens)),
      bottomNavigationBar: _TabBar(
        index: _index,
        onTap: (i) {
          if (i == 2) {
            showCreateSheet(context);
            return;
          }
          setState(() => _index = i);
        },
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _TabBar({required this.index, required this.onTap});

  static const double _barHeight = 60;
  // How far the raised camera button's top edge sits above the bar's own
  // top edge (matches what the old Transform.translate(0, -10) on a 66px
  // button centered in a 60px row worked out to). The bug wasn't this
  // amount of "raise" itself — Instagram/Snapchat-style buttons really do
  // poke up like this on purpose — it's that Transform.translate just
  // painted the button outside the bar Container's own 60px bounds, which
  // Scaffold never knew to reserve space for. That overflow landed directly
  // on top of whatever sat at the very bottom of the screen above the bar
  // (the Chat tab's message composer has no bottom padding, so it was the
  // most visible place it broke). Wrapping everything in a Stack sized to
  // _barHeight + _buttonPoke makes this the bar's real height, so Scaffold
  // reserves the extra space and the button stays inside its own territory.
  static const double _buttonPoke = 13;
  static const double _buttonSize = 66;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return SizedBox(
      height: _barHeight + _buttonPoke,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: _barHeight,
              decoration: BoxDecoration(color: tokens.glass, border: Border(top: BorderSide(color: tokens.line))),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    _TabItem(icon: Icons.home, label: 'Home', active: index == 0, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(0)),
                    _TabItem(icon: Icons.chat_bubble, label: 'Chat', active: index == 1, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(1)),
                    // Empty middle slot — the raised button is drawn
                    // separately below so it can extend above this row
                    // without being clipped by it, but this Expanded still
                    // keeps the side tab items spaced exactly as before.
                    const Expanded(child: SizedBox.shrink()),
                    _TabItem(icon: Icons.location_on, label: 'Places', active: index == 3, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(3)),
                    _TabItem(icon: Icons.person, label: 'Profile', active: index == 4, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(4)),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => onTap(2),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: _buttonSize,
                  height: _buttonSize,
                  decoration: BoxDecoration(
                    color: tokens.brand,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.glass, width: 4),
                    boxShadow: [BoxShadow(color: tokens.brand.withValues(alpha: 0.5), blurRadius: 14, offset: const Offset(0, 5))],
                  ),
                  // A plus instead of a camera — the camera icon made this
                  // button read as "take a photo" specifically, when it
                  // actually opens the full create flow (camera Story,
                  // text Story, poll, or place). A generic "add" symbol
                  // doesn't bias toward any one of those.
                  child: const Icon(Icons.add, color: Colors.white, size: 32),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color color;
  final Color mute;
  final VoidCallback onTap;
  const _TabItem({required this.icon, required this.label, required this.active, required this.color, required this.mute, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? color : mute, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: active ? color : mute, fontSize: 10.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// A short-lived burst of colored squares that fall and fade out from
/// [origin] — the FUNKY-logo easter egg. Removes itself via [onDone] once
/// the animation finishes; nothing here is persisted or interactive.
class _ConfettiBurst extends StatefulWidget {
  final Offset origin;
  final VoidCallback onDone;
  const _ConfettiBurst({required this.origin, required this.onDone});

  @override
  State<_ConfettiBurst> createState() => _ConfettiBurstState();
}

class _Particle {
  final double angle;
  final double speed;
  final double size;
  final Color color;
  final double spin;
  _Particle({required this.angle, required this.speed, required this.size, required this.color, required this.spin});
}

class _ConfettiBurstState extends State<_ConfettiBurst> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  static const _colors = [Color(0xFFFF7A1A), Color(0xFFFFC107), Color(0xFF42A5F5), Color(0xFFE53935), Color(0xFF66BB6A), Color(0xFFAB47BC)];

  @override
  void initState() {
    super.initState();
    final rand = Random();
    _particles = List.generate(26, (_) {
      return _Particle(
        angle: rand.nextDouble() * pi - (pi / 2) - (pi / 4), // mostly upward/outward
        speed: 120 + rand.nextDouble() * 160,
        size: 5 + rand.nextDouble() * 5,
        color: _colors[rand.nextInt(_colors.length)],
        spin: (rand.nextDouble() - 0.5) * 10,
      );
    });
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _controller.forward();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(painter: _ConfettiPainter(origin: widget.origin, t: _controller.value, particles: _particles));
          },
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final Offset origin;
  final double t; // 0..1
  final List<_Particle> particles;
  _ConfettiPainter({required this.origin, required this.t, required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    const gravity = 520.0;
    for (final p in particles) {
      final vx = cos(p.angle) * p.speed;
      final vy = sin(p.angle) * p.speed;
      final dx = vx * t;
      final dy = vy * t + 0.5 * gravity * t * t;
      final opacity = (1 - t).clamp(0.0, 1.0);
      final paint = Paint()..color = p.color.withValues(alpha: opacity);
      canvas.save();
      canvas.translate(origin.dx + dx, origin.dy + dy);
      canvas.rotate(p.spin * t * pi);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 1.6), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => oldDelegate.t != t;
}
