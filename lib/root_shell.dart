import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'data/app_store.dart';
import 'data/geo.dart';
import 'screens/chat_screen.dart';
import 'screens/create_sheet.dart';
import 'screens/home_screen.dart';
import 'screens/places_screen.dart';
import 'screens/profile_screen.dart';
import 'widgets/top_bar_actions.dart';
import 'widgets/ui_widgets.dart';
import 'widgets/rainbow_wordmark.dart';

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

  static const _titles = ['Home', 'Chat', '', 'Map', 'Profile'];

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
                  child: const RainbowWordmark(height: 38),
                ),
              )
            : Text(_titles[_index], style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
        actions: const [NotificationBell(), SettingsGearButton()],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Admin viewing another area: always show it, with a way back.
            const _ViewingElsewhereBanner(),
            Expanded(child: IndexedStack(index: _index, children: _screens)),
          ],
        ),
      ),
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

/// Shown across the top while an admin has dropped their pin somewhere else.
class _ViewingElsewhereBanner extends StatelessWidget {
  const _ViewingElsewhereBanner();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (!store.isViewingElsewhere) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final gps = store.gpsLocation;
    final pin = store.location!;
    final away = gps == null ? null : milesBetween(gps, pin);
    return Material(
      color: tokens.brand,
      child: InkWell(
        onTap: () => store.setLocationOverride(null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.travel_explore, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  away == null ? 'Viewing another area' : 'Viewing an area ${away.round()} mi away',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              const Text('Return to my location', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5, decoration: TextDecoration.underline, decorationColor: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom bar: Home, Chat, a rounded-square orange "+" in the middle
/// (opens the Story/Poll/Place sheet), Map, Profile. Bigger icons and labels,
/// the active tab in orange, everything else soft gray.
class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _TabBar({required this.index, required this.onTap});

  static const double _barHeight = 56;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    // The home-indicator gap sits under the bar (trimmed a little so the bar
    // doesn't sit too high), not inside its 56px, so the icons never get
    // squeezed on Face ID iPhones.
    final rawInset = MediaQuery.paddingOf(context).bottom;
    final bottomInset = rawInset > 20 ? rawInset - 12 : rawInset;
    final unread = context.select<AppStore, int>((s) => s.totalUnreadMessages);
    return Container(
      height: _barHeight + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.line, width: 0.6)),
      ),
      child: Row(
        children: [
          _TabItem(icon: Icons.home_rounded, label: 'Home', active: index == 0, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(0)),
          _TabItem(icon: Icons.chat_bubble_rounded, label: 'Chat', active: index == 1, color: tokens.orange, mute: tokens.mute, badge: unread, onTap: () => onTap(1)),
          Expanded(child: Center(child: _PlusButton(color: tokens.brand, onTap: () => onTap(2)))),
          _TabItem(icon: Icons.map_rounded, label: 'Map', active: index == 3, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(3)),
          _TabItem(icon: Icons.person_rounded, label: 'Profile', active: index == 4, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(4)),
        ],
      ),
    );
  }
}

/// The orange rounded-square "+" — squishes a little while pressed.
class _PlusButton extends StatefulWidget {
  final Color color;
  final VoidCallback onTap;
  const _PlusButton({required this.color, required this.onTap});

  @override
  State<_PlusButton> createState() => _PlusButtonState();
}

class _PlusButtonState extends State<_PlusButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.9 : 1,
        duration: const Duration(milliseconds: 110),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          // A plus, not a camera: it opens the whole create flow (camera
          // Story, text Story, poll, or place).
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
        ),
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
  // Unread messages, shown as a small orange count on the icon.
  final int badge;
  const _TabItem({required this.icon, required this.label, required this.active, required this.color, required this.mute, required this.onTap, this.badge = 0});

  @override
  Widget build(BuildContext context) {
    final c = active ? color : mute;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedScale(
                  scale: active ? 1.08 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(icon, color: c, size: 25),
                ),
                if (badge > 0)
                  Positioned(
                    right: -9,
                    top: -5,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      height: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 1.5),
                      ),
                      child: Text(badge > 99 ? '99+' : '$badge', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: active ? FontWeight.w800 : FontWeight.w600)),
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
