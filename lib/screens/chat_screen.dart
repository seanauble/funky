import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';
import 'person_profile_screen.dart';

/// One shared live chat for everyone within 25 miles — no per-place rooms,
/// no room picker. Just LIVE CHAT with a blinking dot so it feels alive.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  int _segment = 0; // 0 = live chat, 1 = dms
  final _draftController = TextEditingController();
  bool _anon = false;

  @override
  void dispose() {
    _draftController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  _SegButton(label: 'Live Chat', active: _segment == 0, onTap: () => setState(() => _segment = 0)),
                  _SegButton(label: 'Messages', active: _segment == 1, onTap: () => setState(() => _segment = 1)),
                ],
              ),
            ),
            Expanded(
              child: _segment == 1
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: const [
                        EmptyNote(text: 'No messages yet tonight. Find someone in the chat or on a Story, add them, and plan the pregame.'),
                        FootNote(text: 'Private messages and friends stay. Everything else is wiped at 4 PM.'),
                      ],
                    )
                  : store.location == null
                      ? const LocationGate()
                      : const _LiveChat(),
            ),
            if (_segment == 0 && store.location != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: tokens.surface, border: Border(top: BorderSide(color: tokens.line))),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _anon = !_anon),
                        child: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: _anon ? tokens.brand : tokens.raised, shape: BoxShape.circle),
                          child: const Text('👻'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _draftController,
                          maxLength: 240,
                          decoration: InputDecoration(
                            hintText: 'Message',
                            hintStyle: TextStyle(color: tokens.mute),
                            filled: true,
                            fillColor: tokens.raised,
                            counterText: '',
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(19), borderSide: BorderSide.none),
                          ),
                          style: TextStyle(color: tokens.ink),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          final text = _draftController.text.trim();
                          if (text.isEmpty) return;
                          store.sendMessage('main', text, _anon);
                          _draftController.clear();
                        },
                        child: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle),
                          child: const Icon(Icons.arrow_upward, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LiveChat extends StatelessWidget {
  const _LiveChat();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final msgs = store.messagesFor('main');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const _BlinkingDot(),
            const SizedBox(width: 8),
            Text(
              'LIVE CHAT',
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 19, letterSpacing: 0.4),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text('📍 Everyone within 25 miles of you, right now', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
        const SizedBox(height: 16),
        if (msgs.isEmpty) Text('Nobody has said anything here tonight. Start it off.', style: TextStyle(color: tokens.mute)),
        ...msgs.map((m) {
          final handle = m.uid == 'me' ? store.me.handle : (store.people[m.uid]?.handle ?? m.uid);
          Widget nameLine;
          if (m.anon) {
            nameLine = Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12));
          } else if (m.uid == 'me') {
            nameLine = FunkyHandle(handle: handle);
          } else {
            nameLine = GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: m.uid))),
              child: FunkyHandle(handle: handle),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                nameLine,
                const SizedBox(height: 2),
                Text(m.text, style: TextStyle(color: tokens.ink)),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// A small pulsing red dot — the "this is live" indicator next to LIVE CHAT.
class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.25).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
      ),
    );
  }
}

class _SegButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _SegButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? tokens.surface : null,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(color: active ? tokens.ink : tokens.mute, fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
    );
  }
}
