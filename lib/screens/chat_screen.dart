import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'dm_thread_screen.dart';
import 'person_profile_screen.dart';

// The hold-to-react picker's fixed set — "custom" in the sense that it's
// FUNKY's own curated strip rather than the OS's full emoji keyboard, same
// idea as iMessage tapbacks rather than a free-for-all picker.
const _reactionEmojis = ['❤️', '😂', '😮', '😢', '🔥', '👍'];

Future<void> _showReactionPicker(BuildContext context, AppStore store, ChatMessage message) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final chosen = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: tokens.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          children: _reactionEmojis
              .map((e) => InkWell(
                    onTap: () => Navigator.of(context).pop(e),
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(e, style: const TextStyle(fontSize: 30)),
                    ),
                  ))
              .toList(),
        ),
      ),
    ),
  );
  if (chosen != null) store.toggleReaction(message.id, chosen);
}

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
            // ChatScreen normally lives as a bottom tab inside RootShell,
            // which already supplies a shared AppBar + tab bar — nothing
            // extra needed there. But Home's "Open chat" shortcut (see
            // home_screen.dart) pushes this as its own standalone route on
            // top of that, and with no AppBar of its own, the only way back
            // used to be an edge-swipe gesture — easy to miss entirely, or
            // to have swallowed by the keyboard/segmented control, leaving
            // you stuck with nothing tappable to get out. Navigator.canPop
            // is only true in that pushed case, never for the tab itself,
            // so this only ever shows up exactly where it's needed.
            if (Navigator.canPop(context))
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.arrow_back, color: tokens.ink),
                    ),
                    Text('Chat', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
                  ],
                ),
              ),
            Container(
              margin: EdgeInsets.fromLTRB(16, Navigator.canPop(context) ? 8 : 16, 16, 0),
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
                  ? _MessagesList(store: store)
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
                          void send() {
                            final error = store.sendMessage('main', text, _anon);
                            if (error != null) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                              return;
                            }
                            _draftController.clear();
                          }
                          // Reading/browsing the live chat never needs an
                          // account. Sending under your real handle does too
                          // — but a 👻 ghost-mode message never shows a name
                          // either way, so it goes straight through with no
                          // account gate at all.
                          if (_anon) {
                            send();
                          } else {
                            requireAccountThen(context, store, send);
                          }
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

/// The "Messages" segment — every DM thread 'me' has going, most recently
/// active first. NOTE: this only ever reflects DMs sent from this one
/// device (see the comment on AppStore.dmConversations) — there's no
/// backend yet to actually deliver a message to someone else's phone.
class _MessagesList extends StatelessWidget {
  final AppStore store;
  const _MessagesList({required this.store});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final conversations = store.dmConversations;

    if (conversations.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          EmptyNote(text: 'No messages yet tonight. Find someone in the chat or on a Story, add them, and plan the pregame.'),
          FootNote(text: 'Private messages and friends stay. Everything else is wiped at 2 PM.'),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: conversations.length,
      itemBuilder: (context, i) {
        final person = conversations[i];
        final isFriend = store.isFriendsWith(person.id);
        final room = dmRoomId('me', person.id);
        final msgs = store.messagesFor(room);
        final last = msgs.isNotEmpty ? msgs.last : null;
        return ListTile(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: person.id))),
          leading: Container(
            padding: EdgeInsets.all(isFriend ? 2 : 0),
            decoration: isFriend ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.friend, width: 2)) : null,
            child: FunkyAvatar(seed: person.id, label: person.handle.isNotEmpty ? person.handle : '?', size: 44, photoPath: person.photoPath),
          ),
          title: StyledName(person: person, text: '@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
          subtitle: last == null
              ? null
              : Text(
                  last.uid == 'me' ? 'You: ${last.text}' : last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.mute),
                ),
        );
      },
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
          final sender = m.uid == 'me' ? store.me : store.people[m.uid];
          final handle = sender?.handle ?? m.uid;
          Widget nameLine;
          if (m.anon) {
            nameLine = Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12));
          } else if (m.uid == 'me') {
            nameLine = FunkyHandle(handle: handle, person: sender);
          } else {
            nameLine = GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: m.uid))),
              child: FunkyHandle(handle: handle, person: sender),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              // Double-tap for a quick ❤️ (toggles it back off if you
              // already reacted with a heart) — hold for the full strip.
              onDoubleTap: () => store.toggleReaction(m.id, '❤️'),
              onLongPress: () => _showReactionPicker(context, store, m),
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  nameLine,
                  const SizedBox(height: 2),
                  Text(m.text, style: TextStyle(color: tokens.ink)),
                  if (m.reactions.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: m.reactions.entries.map((entry) {
                        final mine = entry.value.contains('me');
                        return GestureDetector(
                          onTap: () => store.toggleReaction(m.id, entry.key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: mine ? tokens.brand.withValues(alpha: 0.18) : tokens.raised,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: mine ? tokens.brand : tokens.line, width: 1),
                            ),
                            child: Text(
                              '${entry.key} ${entry.value.length}',
                              style: TextStyle(color: tokens.ink, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
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
