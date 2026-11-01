import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../data/when_labels.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/org_badge.dart';
import '../widgets/poll_bars.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'place_detail_screen.dart';

/// Reactions you get when you hold a message — FUNKY's own short set, like
/// iMessage tapbacks.
const liveChatReactions = ['❤️', '😂', '👀', '🔥', '😮', '👍'];

/// The area chat: who's around up top, then the messages, newest at the
/// bottom. [onReply] starts a reply to a message.
class LiveChatView extends StatefulWidget {
  final ValueChanged<ChatMessage> onReply;
  const LiveChatView({super.key, required this.onReply});

  @override
  State<LiveChatView> createState() => _LiveChatViewState();
}

class _LiveChatViewState extends State<LiveChatView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().refreshOnlineNearby();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final msgs = store.liveChatMessages;

    // Newest first, because the list is drawn bottom-up.
    final items = <Widget>[];
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      items.add(LiveChatBubble(key: ValueKey(m.id), message: m, onReply: widget.onReply));
      final prev = i > 0 ? msgs[i - 1] : null;
      // A time stamp above the first message and after a 20-minute gap.
      if (prev == null || m.t - prev.t > 20 * 60 * 1000) items.add(_TimeDivider(t: m.t));
    }

    return Column(
      children: [
        const _AreaHeader(),
        Divider(height: 1, thickness: 1, color: tokens.line),
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      "Nobody's said anything here tonight.\nStart it off: what's the move?",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: tokens.mute, fontSize: 14.5, height: 1.4),
                    ),
                  ),
                )
              : ListView(
                  reverse: true,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  children: items,
                ),
        ),
      ],
    );
  }
}

/// "Somers Point · ● 18 online · Within 10 miles"
class _AreaHeader extends StatelessWidget {
  const _AreaHeader();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final online = store.onlineNearby;
    final area = store.areaName ?? 'Your area';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(area, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 19)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const _OnlineDot(),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        online == null ? 'Within ${rangeLabel()}' : '$online online · Within ${rangeLabel()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tokens.mute, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A softly pulsing green dot — people are here right now.
class _OnlineDot extends StatefulWidget {
  const _OnlineDot();

  @override
  State<_OnlineDot> createState() => _OnlineDotState();
}

class _OnlineDotState extends State<_OnlineDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.35).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(width: 9, height: 9, decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle)),
    );
  }
}

class _TimeDivider extends StatelessWidget {
  final int t;
  const _TimeDivider({required this.t});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final label = sameDay ? 'Today, ${clockLabel(d)}' : '${dayLabel(d)}, ${clockLabel(d)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(child: Text(label, style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w600))),
    );
  }
}

/// Hold a message: react, reply, copy, (admins) delete.
Future<void> showLiveChatActions(BuildContext context, AppStore store, ChatMessage m, ValueChanged<ChatMessage> onReply) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  HapticFeedback.mediumImpact();
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: tokens.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in liveChatReactions)
                    InkWell(
                      onTap: () => Navigator.of(sheetContext).pop('react:$e'),
                      customBorder: const CircleBorder(),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: (m.reactions[e]?.contains('me') ?? false)
                            ? BoxDecoration(color: tokens.brand.withValues(alpha: 0.2), shape: BoxShape.circle)
                            : null,
                        child: Text(e, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.reply_rounded, color: tokens.ink),
              title: Text('Reply', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              onTap: () => Navigator.of(sheetContext).pop('reply'),
            ),
            if (m.text.trim().isNotEmpty)
              ListTile(
                leading: Icon(Icons.copy_rounded, color: tokens.ink),
                title: Text('Copy text', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
            // Only a FUNKY Admin sees this.
            if (store.isAdmin)
              ListTile(
                leading: Icon(Icons.delete_outline, color: tokens.danger),
                title: Text('Delete message (Admin)', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action.startsWith('react:')) {
    final emoji = action.substring(6);
    await requireAccountThen(context, store, () => store.toggleReaction(m.id, emoji));
  } else if (action == 'reply') {
    onReply(m);
  } else if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: m.text));
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.'), duration: Duration(seconds: 1)));
  } else if (action == 'delete') {
    store.deleteMessage(m.id);
  }
}

/// One Live Chat message: avatar and name (others), the bubble with any
/// quoted reply, spot, poll or GIF, and the reaction counts under it. Hold
/// to react or reply; swipe right to reply; double-tap for a quick ❤️.
class LiveChatBubble extends StatefulWidget {
  final ChatMessage message;
  final ValueChanged<ChatMessage> onReply;
  const LiveChatBubble({super.key, required this.message, required this.onReply});

  @override
  State<LiveChatBubble> createState() => _LiveChatBubbleState();
}

class _LiveChatBubbleState extends State<LiveChatBubble> {
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final m = widget.message;
    final mine = m.uid == 'me';
    final sender = mine ? (store.signedIn ? store.me : null) : store.people[m.uid];
    final handle = store.chatHandleFor(m);

    final avatar = m.anon || (mine && !store.signedIn)
        ? const GhostAvatar(size: 36)
        : (sender != null ? PersonAvatar(person: sender, size: 36) : FunkyAvatar(seed: m.uid, label: handle.isNotEmpty ? handle : '?', size: 36));

    final bubbleColor = mine ? tokens.brand.withValues(alpha: 0.16) : tokens.raised;
    final content = <Widget>[
      if (m.isReply) _ReplyQuote(handle: m.replyHandle ?? 'someone', text: m.replyText ?? '', mine: mine),
      if (m.text.trim().isNotEmpty)
        filteredMessageText(m.text, TextStyle(color: tokens.ink, fontSize: 15.5, height: 1.3), myHandle: store.me.handle, mentions: true),
    ];
    final hasBubble = content.isNotEmpty;

    final column = Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (!mine)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: m.anon
                      ? Text('anonymous', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 13))
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => openProfile(context, m.uid),
                          child: FunkyHandle(handle: handle, person: sender),
                        ),
                ),
                if (m.lat != null && m.lng != null && store.location != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    awayLabel(milesBetween(store.location!, LatLng(m.lat!, m.lng!))),
                    style: TextStyle(color: tokens.mute, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        if (hasBubble)
          Container(
            constraints: const BoxConstraints(maxWidth: 290),
            padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 6),
                bottomRight: Radius.circular(mine ? 6 : 18),
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: content),
          ),
        if (m.gifUrl != null) ...[
          if (hasBubble) const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230, maxHeight: 220, minHeight: 80, minWidth: 80),
              child: Image.network(
                m.gifUrl!,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, p) => p == null ? child : Container(width: 180, height: 140, color: tokens.raised),
                errorBuilder: (_, __, ___) => Container(width: 180, height: 60, color: tokens.raised, alignment: Alignment.center, child: Text('GIF', style: TextStyle(color: tokens.mute))),
              ),
            ),
          ),
        ],
        if (m.sharedPlaceId != null) ...[
          if (hasBubble || m.gifUrl != null) const SizedBox(height: 4),
          LiveChatSpotCard(placeId: m.sharedPlaceId!),
        ],
        if (m.pollId != null) ...[
          if (hasBubble || m.gifUrl != null || m.sharedPlaceId != null) const SizedBox(height: 4),
          LiveChatPollCard(pollId: m.pollId!),
        ],
        if (m.reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: m.reactions.entries.map((entry) {
                final reacted = entry.value.contains('me');
                return GestureDetector(
                  onTap: () => requireAccountThen(context, store, () => store.toggleReaction(m.id, entry.key)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: reacted ? tokens.brand.withValues(alpha: 0.14) : tokens.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: reacted ? tokens.brand : tokens.line),
                    ),
                    child: Text('${entry.key} ${entry.value.length}', style: TextStyle(color: tokens.ink, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                );
              }).toList(),
            ),
          ),
        if (mine)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 2),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: m.status == 'failed' ? () => store.retryChatMessage(m.id) : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        m.status == 'failed'
                            ? 'Not sent · tap to retry'
                            : (m.status == 'sending' ? 'Sending…' : clockLabel(DateTime.fromMillisecondsSinceEpoch(m.t))),
                        style: TextStyle(color: m.status == 'failed' ? tokens.danger : tokens.mute, fontSize: 11.5),
                      ),
                      if (m.status != 'failed' && m.status != 'sending') ...[
                        const SizedBox(width: 3),
                        Icon(Icons.check_rounded, size: 14, color: tokens.brand),
                      ],
                    ],
                  ),
                  if (m.status == 'failed' && store.sendErrorFor(m.id) != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(store.sendErrorFor(m.id)!, textAlign: TextAlign.right, style: TextStyle(color: tokens.mute, fontSize: 10.5)),
                    ),
                ],
              ),
            ),
          ),
      ],
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!mine) ...[avatar, const SizedBox(width: 10)],
        Flexible(child: column),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => requireAccountThen(context, store, () => store.toggleReaction(m.id, '❤️')),
      onLongPress: () => showLiveChatActions(context, store, m, widget.onReply),
      onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(0.0, 70.0)),
      onHorizontalDragEnd: (_) {
        if (_drag > 48) {
          HapticFeedback.selectionClick();
          widget.onReply(m);
        }
        setState(() => _drag = 0);
      },
      onHorizontalDragCancel: () => setState(() => _drag = 0),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Stack(
          children: [
            if (_drag > 8)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(child: Icon(Icons.reply_rounded, color: tokens.mute.withValues(alpha: (_drag / 70).clamp(0.0, 1.0)))),
              ),
            AnimatedContainer(
              duration: _drag == 0 ? const Duration(milliseconds: 180) : Duration.zero,
              transform: Matrix4.translationValues(_drag, 0, 0),
              child: row,
            ),
          ],
        ),
      ),
    );
  }
}

/// The quoted message at the top of a reply.
class _ReplyQuote extends StatelessWidget {
  final String handle;
  final String text;
  final bool mine;
  const _ReplyQuote({required this.handle, required this.text, required this.mine});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: tokens.bg.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: mine ? tokens.brand : tokens.mute, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(handle == 'anonymous' ? 'anonymous' : '@$handle', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 12)),
          if (text.isNotEmpty)
            Text(maskBadWords(text), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 13)),
        ],
      ),
    );
  }
}

/// A spot someone shared: its picture, name, where, and "I'm going".
class LiveChatSpotCard extends StatelessWidget {
  final String placeId;
  const LiveChatSpotCard({super.key, required this.placeId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final ranked = store.rankedPlaceById(placeId);
    if (ranked == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
        child: Text('📍 A spot that isn\'t listed anymore', style: TextStyle(color: tokens.mute)),
      );
    }
    final p = ranked.place;
    final upcoming = store.isPlaceUpcoming(p);
    final going = upcoming ? store.hasRsvped(p.id) : store.me.move == p.id;
    final sub = [
      if (p.startsAt != null) upcoming ? dayLabel(p.startsAt!) : 'Tonight ${clockLabel(p.startsAt!)}',
      store.areaName ?? placeKindLabel(p.kind),
    ].join(' · ');
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 104,
              height: 78,
              child: OrgBadgeCorner(
                badge: placeOrgBadge(p),
                small: true,
                inset: 4,
                child: PlaceMediaThumbnail(
                  story: store.latestMediaStoryFor(p.id),
                  coverPhotoPath: p.coverPhotoPath,
                  coverUrl: p.coverUrl,
                  photoUrl: p.photoUrl,
                  fallbackLabel: p.name.isNotEmpty ? p.name.substring(0, 1) : '?',
                  fontSize: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10, left: 6),
              child: GestureDetector(
                onTap: () {
                  if (upcoming) {
                    requireAccountThen(context, store, () => store.togglePlaceRsvp(p.id));
                  } else {
                    store.setMove(going ? 'in' : p.id);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(color: going ? tokens.raised : tokens.orange, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    going ? 'Going ✓' : "I'm going",
                    style: TextStyle(color: going ? tokens.ink : tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A poll someone shared, votable right in the chat.
class LiveChatPollCard extends StatelessWidget {
  final String pollId;
  const LiveChatPollCard({super.key, required this.pollId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    Poll? poll;
    for (final p in store.polls) {
      if (p.id == pollId) {
        poll = p;
        break;
      }
    }
    if (poll == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
        child: Text('📊 This poll has ended', style: TextStyle(color: tokens.mute)),
      );
    }
    final p = poll;
    final counts = store.pollCounts(p);
    final total = counts.fold<int>(0, (a, b) => a + b);
    return Container(
      constraints: const BoxConstraints(maxWidth: 330),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(maskBadWords(p.q), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 8),
          PollBars(options: p.options, counts: counts, selectedIndex: store.me.votes[p.id], onSelect: (i) => store.votePoll(p.id, i)),
          const SizedBox(height: 6),
          Text(total == 1 ? '1 vote' : '$total votes', style: TextStyle(color: tokens.mute, fontSize: 12)),
        ],
      ),
    );
  }
}
