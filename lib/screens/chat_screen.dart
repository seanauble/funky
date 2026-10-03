import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';

class ChatScreen extends StatefulWidget {
  /// The room to open directly into — a place's id for that place's chat,
  /// or omitted/'main' for Area chat. Lets "Open this place's chat" on the
  /// place detail screen land in that place's room instead of always
  /// falling back to the one shared area chat.
  final String? initialRoom;
  const ChatScreen({super.key, this.initialRoom});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  int _segment = 0; // 0 = area, 1 = dms
  late String _room;
  final _draftController = TextEditingController();
  bool _anon = false;

  @override
  void initState() {
    super.initState();
    _room = widget.initialRoom ?? 'main';
  }

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
                  _SegButton(label: 'Area chat', active: _segment == 0, onTap: () => setState(() => _segment = 0)),
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
                      : _AreaChat(room: _room, onRoomChange: (r) => setState(() => _room = r)),
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
                          store.sendMessage(_room, text, _anon);
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

class _AreaChat extends StatelessWidget {
  final String room;
  final ValueChanged<String> onRoomChange;
  const _AreaChat({required this.room, required this.onRoomChange});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final msgs = store.messagesFor(room);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: store.roomsForChat
                .map((r) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FunkyChip(label: r.heat >= 2 ? '${r.name} 🔥' : r.name, active: r.id == room, onPressed: () => onRoomChange(r.id)),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          msgs.isNotEmpty ? 'Only people within 25 miles can talk here' : 'Nobody has said anything here tonight. Start it off.',
          style: TextStyle(color: tokens.mute),
        ),
        const SizedBox(height: 10),
        ...msgs.map((m) {
          final handle = m.uid == 'me' ? store.me.handle : (store.people[m.uid]?.handle ?? m.uid);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                m.anon ? Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12)) : FunkyHandle(handle: handle),
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
