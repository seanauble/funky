import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/chat_cards.dart';
import '../widgets/ios_ui.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';

/// The chat on a party or event's page: questions for the host, plans,
/// who's bringing what. A private event's chat is only for its guests.
class EventChatScreen extends StatefulWidget {
  final String placeId;
  const EventChatScreen({super.key, required this.placeId});

  @override
  State<EventChatScreen> createState() => _EventChatScreenState();
}

class _EventChatScreenState extends State<EventChatScreen> {
  final _controller = TextEditingController();
  Timer? _poll;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    // New messages show up within a few seconds while you're here.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final err = await context.read<AppStore>().fetchEventMessages(widget.placeId);
    if (mounted && err != _error) setState(() => _error = err);
  }

  void _send(AppStore store) {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    requireAccountThen(context, store, () async {
      setState(() => _sending = true);
      final err = await store.sendEventMessage(widget.placeId, text);
      if (!mounted) return;
      setState(() => _sending = false);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _controller.clear();
    });
  }

  Future<void> _actions(AppStore store, EventMessage m, bool canDelete) async {
    final choice = await showIosActionSheet<String>(
      context,
      message: maskBadWords(m.text),
      actions: [
        if (m.uid != 'me') const IosSheetAction('View profile', 'profile', icon: Icons.person_outline_rounded),
        if (canDelete) const IosSheetAction('Delete message', 'delete', destructive: true, icon: Icons.delete_outline_rounded),
      ],
    );
    if (!mounted) return;
    if (choice == 'profile') openProfile(context, m.uid);
    if (choice == 'delete') await store.deleteEventMessage(m);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    Place? place;
    for (final p in store.places) {
      if (p.id == widget.placeId) {
        place = p;
        break;
      }
    }
    final insider = place == null || store.isEventInsider(place);
    final hostUid = place?.by;
    final isHost = hostUid == 'me';
    final messages = store.eventMessages(widget.placeId);
    final loaded = store.eventMessagesLoaded(widget.placeId);

    Widget body;
    if (!insider) {
      body = _Note(icon: Icons.lock_outline_rounded, text: 'This chat is for guests. Enter the host\'s code on the event page to join.');
    } else if (_error != null && messages.isEmpty) {
      body = _Note(icon: Icons.cloud_off_rounded, text: _error!);
    } else if (!loaded) {
      body = const Center(child: CircularProgressIndicator.adaptive());
    } else if (messages.isEmpty) {
      body = _Note(
        icon: Icons.forum_outlined,
        text: isHost ? 'No messages yet. Say hi, share the plan, or answer questions here.' : 'No messages yet. Ask the host anything or make plans with everyone going.',
      );
    } else {
      body = ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        itemCount: messages.length,
        itemBuilder: (context, i) {
          final m = messages[messages.length - 1 - i];
          final prev = messages.length - 2 - i >= 0 ? messages[messages.length - 2 - i] : null;
          // Back-to-back messages from the same person within 5 minutes
          // stack under one name.
          final grouped = prev != null && prev.uid == m.uid && m.t - prev.t < 5 * 60 * 1000;
          final canDelete = m.uid == 'me' || isHost || store.isAdmin || (place != null && store.canManageEvent(place));
          return _EventBubble(
            message: m,
            grouped: grouped,
            role: place == null ? (m.uid == hostUid ? 'host' : null) : store.roleAt(place, m.uid),
            onLongPress: () => _actions(store, m, canDelete),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Column(
          children: [
            const Text('Event chat', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            if (place != null)
              Text(
                place.isPrivate ? '🔒 ${place.name}' : place.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: body),
          if (insider)
            ComposerArea(
              color: tokens.bg,
              border: Border(top: BorderSide(color: tokens.line, width: 0.5)),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Row(
                  children: [
                    // Hosts and co-hosts can drop a payment card for entry.
                    if (place != null && store.signedIn && store.canManageEvent(place))
                      IconButton(
                        tooltip: 'Request money',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          final card = await showPayCardSheet(context, note: place!.name, placeId: place.id, amount: place.entryPrice);
                          if (card == null || !context.mounted) return;
                          final err = await store.sendEventMessage(widget.placeId, '', card: card);
                          if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                        },
                        icon: Icon(Icons.attach_money_rounded, color: tokens.brand),
                      ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        maxLength: 500,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        style: TextStyle(color: tokens.ink, fontSize: 15),
                        decoration: InputDecoration(
                          hintText: store.signedIn ? (isHost ? 'Message your guests…' : 'Ask a question or say something…') : 'Make an account to chat',
                          hintStyle: TextStyle(color: tokens.mute),
                          filled: true,
                          fillColor: tokens.raised,
                          counterText: '',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                        ),
                        onTap: store.signedIn ? null : () => requireAccountThen(context, store, () {}),
                        readOnly: !store.signedIn,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _send(store),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: tokens.orange, shape: BoxShape.circle),
                        child: _sending
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Note({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: tokens.mute, size: 38),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: tokens.mute, height: 1.35)),
          ],
        ),
      ),
    );
  }
}

/// One message: avatar, @handle (with a Host tag), time, text.
class _EventBubble extends StatelessWidget {
  final EventMessage message;
  final bool grouped;
  // 'host', 'cohost', 'door' or null.
  final String? role;
  final VoidCallback onLongPress;
  const _EventBubble({required this.message, required this.grouped, required this.role, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = message.uid == 'me' ? store.me : store.personById(message.uid);
    final handle = message.uid == 'me' ? store.myChatHandle : (person?.handle ?? 'someone');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.only(top: grouped ? 2 : 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              child: grouped
                  ? null
                  : GestureDetector(
                      onTap: () => openProfile(context, message.uid),
                      child: person != null
                          ? PersonAvatar(person: person, size: 32, preview: false)
                          : FunkyAvatar(seed: message.uid, label: '?', size: 32),
                    ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!grouped)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              message.uid == 'me' ? 'You' : '@$handle',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 13.5),
                            ),
                          ),
                          if (role != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(999)),
                              child: Text(
                                role == 'host' ? 'Host' : role == 'cohost' ? 'Co-host' : 'Door',
                                style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 10.5),
                              ),
                            ),
                          ],
                          const SizedBox(width: 6),
                          Text(timeAgoLabel(message.t), style: TextStyle(color: tokens.mute, fontSize: 11.5)),
                        ],
                      ),
                    ),
                  if (message.card != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: ChatCardView(
                        card: message.card!,
                        mine: message.uid == 'me',
                        fromUid: message.uid,
                        kind: 'event',
                        messageId: message.id,
                        eventId: message.placeId,
                      ),
                    ),
                  if (message.text.isNotEmpty)
                    filteredMessageText(message.text, TextStyle(color: tokens.ink, fontSize: 15, height: 1.3), myHandle: store.myChatHandle, mentions: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
