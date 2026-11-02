import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../data/when_labels.dart';
import '../widgets/avatar_preview.dart';

/// Your pass for a private event — show it at the door. A moving rainbow
/// and a live clock, so a screenshot of someone else's doesn't pass.
class EventPassScreen extends StatefulWidget {
  final String placeId;
  const EventPassScreen({super.key, required this.placeId});

  @override
  State<EventPassScreen> createState() => _EventPassScreenState();
}

class _EventPassScreenState extends State<EventPassScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  late final Timer _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().fetchEventGuests(widget.placeId);
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    _spin.dispose();
    super.dispose();
  }

  String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    String two(int n) => n.toString().padLeft(2, '0');
    return '$h:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    Place? p;
    for (final x in store.places) {
      if (x.id == widget.placeId) p = x;
    }
    EventGuest? mine;
    for (final g in store.eventGuests(widget.placeId)) {
      if (g.uid == 'me') mine = g;
    }
    final status = store.myEventStatus(widget.placeId) ?? mine?.status;
    final onList = status != null;
    final checkedIn = mine?.checkedInAt;
    final role = p == null ? null : store.eventRole(p);
    final start = p?.shownTime;
    final label = checkedIn != null
        ? 'Checked in ${clockLabel(checkedIn)}'
        : role == 'host'
            ? 'Host'
            : role == 'cohost'
                ? 'Co-host'
                : role == 'door'
                    ? 'Door'
                    : status == 'cant'
                        ? "Said you can't make it"
                        : onList
                            ? 'On the list ✓'
                            : 'Not on the list';

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            gradient: SweepGradient(
              transform: GradientRotation(_spin.value * 2 * pi),
              colors: const [
                Color(0xFFFF3B6B),
                Color(0xFFFF9F1C),
                Color(0xFFFFE14D),
                Color(0xFF3DDC84),
                Color(0xFF3AA8FF),
                Color(0xFFA259FF),
                Color(0xFFFF3B6B),
              ],
            ),
          ),
          child: child,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
                  ),
                ),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.84), borderRadius: BorderRadius.circular(26)),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: onList ? const Color(0xFF3DDC84) : Colors.white24, width: 3),
                        ),
                        child: PersonAvatar(person: store.me, size: 112, preview: false),
                      ),
                      const SizedBox(height: 12),
                      Text('@${store.me.handle}', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 14),
                      Text(
                        p?.name ?? 'Private event',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 24, height: 1.1),
                      ),
                      if (start != null) ...[
                        const SizedBox(height: 4),
                        Text('${dayLabel(start)} · ${clockLabel(start)}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      ],
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: onList || role != null ? const Color(0xFF3DDC84) : Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(label, style: TextStyle(color: onList || role != null ? Colors.black : Colors.white, fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(height: 16),
                      Text(_clock(_now),
                          style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(height: 2),
                      const Text("live time — a screenshot won't tick", style: TextStyle(color: Colors.white54, fontSize: 11.5)),
                    ],
                  ),
                ),
                const Spacer(),
                const Text('Show this at the door', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 4),
                const Text('They match your face and check you in.', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
