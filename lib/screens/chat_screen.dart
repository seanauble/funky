import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/group_models.dart';
import '../data/models.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'dm_thread_screen.dart';
import 'group_thread_screen.dart';
import '../services/share_links.dart';
import '../widgets/avatar_preview.dart';

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
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              children: _reactionEmojis
                  .map((e) => InkWell(
                        onTap: () => Navigator.of(sheetContext).pop(e),
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(e, style: const TextStyle(fontSize: 30)),
                        ),
                      ))
                  .toList(),
            ),
            // Only a signed-in FUNKY Admin ever sees this — same hardcoded-
            // admin gate as the place verification/ban controls elsewhere.
            // Deletes immediately (no extra confirm) since a single chat
            // message is low-stakes compared to a place or a ban.
            if (store.isAdmin) ...[
              const Divider(height: 24),
              TextButton.icon(
                onPressed: () {
                  store.deleteMessage(message.id);
                  Navigator.of(sheetContext).pop();
                },
                icon: Icon(Icons.delete_outline, color: tokens.danger),
                label: Text('Delete message (Admin)', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  if (chosen != null) requireAccountThen(context, store, () => store.toggleReaction(message.id, chosen));
}

/// The pop-up shown the moment you flip on ghost mode in Live Chat — the
/// only place anonymous mode lives now (it used to also be a switch on the
/// profile page, which made it unclear what it actually covered).
void _showAnonymousDialog(BuildContext context) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('👀👻', textAlign: TextAlign.center, style: TextStyle(fontSize: 44)),
      content: Text(
        "You've entered anonymous mode 👀👻\n\nYour name and profile picture are hidden on every Live Chat message you send until you tap the ghost again.",
        textAlign: TextAlign.center,
        style: TextStyle(color: tokens.ink, fontSize: 15, height: 1.35),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text('Got it', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
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
  final _draftController = MentionTextController();
  bool _anon = false;

  // The "@" picker: while the word being typed starts with "@", people whose
  // name matches are listed above the message box; tapping one fills it in.
  List<Person> _mentionSuggestions = [];
  String? _mentionQuery;
  Timer? _mentionSearchTimer;

  @override
  void initState() {
    super.initState();
    _draftController.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    _mentionSearchTimer?.cancel();
    _draftController.removeListener(_onDraftChanged);
    _draftController.dispose();
    super.dispose();
  }

  /// The "@word" the cursor is currently at the end of, or null.
  RegExpMatch? _activeMention() {
    final sel = _draftController.selection;
    final text = _draftController.text;
    final caret = sel.baseOffset;
    if (!sel.isValid || caret < 0 || caret > text.length) return null;
    return RegExp(r'(?:^|\s)@([A-Za-z0-9_]{0,30})$').firstMatch(text.substring(0, caret));
  }

  void _onDraftChanged() {
    final match = _activeMention();
    if (match == null) {
      if (_mentionQuery != null || _mentionSuggestions.isNotEmpty) {
        setState(() {
          _mentionQuery = null;
          _mentionSuggestions = [];
        });
      }
      return;
    }
    final query = match.group(1) ?? '';
    final store = context.read<AppStore>();
    setState(() {
      _mentionQuery = query;
      _mentionSuggestions = store.mentionCandidates(query);
    });
    // Anyone signed up, not just people already on this phone — looked up
    // a moment after you stop typing.
    _mentionSearchTimer?.cancel();
    if (query.isEmpty) return;
    _mentionSearchTimer = Timer(const Duration(milliseconds: 300), () async {
      final added = await store.lookupMentionHandles(query);
      if (!mounted || !added || _mentionQuery != query) return;
      setState(() => _mentionSuggestions = store.mentionCandidates(query));
    });
  }

  void _insertMention(Person person) {
    final match = _activeMention();
    if (match == null) return;
    final caret = _draftController.selection.baseOffset;
    final text = _draftController.text;
    final atIndex = text.substring(0, caret).lastIndexOf('@');
    if (atIndex < 0) return;
    final inserted = '@${person.handle} ';
    final next = text.substring(0, atIndex) + inserted + text.substring(caret);
    _draftController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: atIndex + inserted.length),
    );
    setState(() {
      _mentionQuery = null;
      _mentionSuggestions = [];
    });
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
            // ChatScreen only ever lives as a bottom tab inside RootShell
            // now, which already supplies a shared AppBar + tab bar — see
            // rootShellTabRequest in root_shell.dart for how Home's "Open
            // chat" shortcut switches to this tab instead of pushing a
            // standalone copy of this screen (which is what used to leave
            // people stuck in here with no way back out).
            // Two plain tabs with an orange line under the one you're on.
            _ChatTabs(
              index: _segment,
              unread: store.totalUnreadMessages,
              onTap: (i) => setState(() => _segment = i),
            ),
            Expanded(
              child: _segment == 1
                  ? _MessagesList(store: store)
                  : store.location == null
                      ? const LocationGate()
                      : const _LiveChat(),
            ),
            if (_segment == 0 && store.location != null && _mentionSuggestions.isNotEmpty)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 230),
                decoration: BoxDecoration(color: tokens.surface, border: Border(top: BorderSide(color: tokens.line))),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
                  children: [
                    for (final person in _mentionSuggestions)
                      InkWell(
                        onTap: () => _insertMention(person),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(
                            children: [
                              PersonAvatar(person: person, size: 30, preview: false),
                              const SizedBox(width: 10),
                              Expanded(child: Text('@${person.handle}', style: const TextStyle(color: mentionColor, fontWeight: FontWeight.w800))),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
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
                        onTap: () {
                          final turningOn = !_anon;
                          setState(() => _anon = turningOn);
                          if (turningOn) _showAnonymousDialog(context);
                        },
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
                            requireGuestOkThen(context, store, send);
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

/// The "Messages" segment — every DM thread and group, most recently active
/// first, with a search bar on top.
class _MessagesList extends StatefulWidget {
  final AppStore store;
  const _MessagesList({required this.store});

  @override
  State<_MessagesList> createState() => _MessagesListState();
}

class _MessagesListState extends State<_MessagesList> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// "now", "2m", "18m", "1h", "3d", or "10/4" for older threads.
  static String _ago(int t) {
    if (t <= 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t));
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${d.month}/${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = widget.store;
    final q = _query.trim().toLowerCase();

    // DMs and groups in one list, newest activity first.
    final entries = <_ConvoEntry>[];
    for (final person in store.dmConversations) {
      final room = dmRoomId('me', person.id);
      final msgs = store.messagesFor(room);
      entries.add(_ConvoEntry(person: person, room: room, msgs: msgs, t: msgs.isNotEmpty ? msgs.last.t : 0));
    }
    for (final g in store.groupConversations) {
      final msgs = store.messagesFor(g.room);
      entries.add(_ConvoEntry(group: g, room: g.room, msgs: msgs, t: msgs.isNotEmpty ? msgs.last.t : g.createdAt.millisecondsSinceEpoch));
    }
    entries.sort((a, b) => b.t.compareTo(a.t));

    // Search: matches a name/@handle/group name, or anything said in the
    // thread (then that message is what's previewed).
    final shown = <(_ConvoEntry, ChatMessage?)>[];
    for (final e in entries) {
      final last = e.msgs.isNotEmpty ? e.msgs.last : null;
      if (q.isEmpty) {
        shown.add((e, last));
        continue;
      }
      final name = e.group?.name ?? e.person?.handle ?? '';
      if (name.toLowerCase().contains(q)) {
        shown.add((e, last));
        continue;
      }
      ChatMessage? hit;
      for (final m in e.msgs.reversed) {
        if (m.text.toLowerCase().contains(q)) {
          hit = m;
          break;
        }
      }
      if (hit != null) shown.add((e, hit));
    }

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(child: Text('Messages', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800))),
          TextButton.icon(
            onPressed: () => requireAccountThen(
              context,
              store,
              () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateGroupScreen())),
            ),
            icon: Icon(Icons.group_add_outlined, size: 18, color: tokens.brand),
            label: Text('New group', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 13.5)),
          ),
        ],
      ),
    );

    final searchBar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        style: TextStyle(color: tokens.ink, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search messages',
          hintStyle: TextStyle(color: tokens.mute, fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded, color: tokens.mute, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close_rounded, color: tokens.mute, size: 20),
                  onPressed: () => setState(() {
                    _search.clear();
                    _query = '';
                  }),
                ),
          filled: true,
          fillColor: tokens.surface,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tokens.line)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tokens.brand, width: 1.4)),
        ),
      ),
    );

    final invite = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => shareFunkyInvite(context, handle: store.signedIn ? store.me.handle : null),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tokens.line),
          ),
          child: Row(
            children: [
              Icon(Icons.people_outline_rounded, color: tokens.ink, size: 21),
              const SizedBox(width: 12),
              Expanded(child: Text('Bring your friends to Funky', style: TextStyle(color: tokens.ink, fontSize: 14, fontWeight: FontWeight.w600))),
              Icon(Icons.chevron_right_rounded, color: tokens.ink),
            ],
          ),
        ),
      ),
    );

    final rows = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      final (e, preview) = shown[i];
      rows.add(_ConvoRow(entry: e, preview: preview, time: _ago(preview?.t ?? e.t), store: store));
      if (i < shown.length - 1) {
        rows.add(Divider(height: 1, thickness: 0.6, indent: 16 + 48 + 12, endIndent: 16, color: tokens.line));
      }
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.translucent,
      child: ListView(
        padding: EdgeInsets.zero,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          searchBar,
          header,
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: EmptyNote(text: 'No messages yet tonight. Find someone in the chat or on a Story, add them, and plan the pregame.'),
            )
          else if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: EmptyNote(text: 'Nothing matches "${_query.trim()}".'),
            )
          else
            ...rows,
          invite,
        ],
      ),
    );
  }
}

/// One conversation row: big picture (green dot when they're online), name,
/// last message, how long ago, and an orange unread count.
class _ConvoRow extends StatelessWidget {
  final _ConvoEntry entry;
  final ChatMessage? preview;
  final String time;
  final AppStore store;
  const _ConvoRow({required this.entry, required this.preview, required this.time, required this.store});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final group = entry.group;
    final person = entry.person;
    final unread = store.unreadCountFor(entry.room);
    final hasUnread = unread > 0;
    final online = person != null && store.isOnline(person.id);
    final isFriend = person != null && store.isFriendsWith(person.id);

    const avatarSize = 48.0;
    Widget avatar;
    if (group != null) {
      avatar = GroupAvatar(group: group, size: avatarSize);
    } else {
      avatar = Container(
        width: avatarSize,
        height: avatarSize,
        padding: EdgeInsets.all(isFriend ? 2 : 0),
        decoration: isFriend ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.friend, width: 1.8)) : null,
        child: PersonAvatar(person: person!, size: isFriend ? avatarSize - 7.6 : avatarSize),
      );
    }
    avatar = SizedBox(
      width: avatarSize,
      height: avatarSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          if (online)
            Positioned(
              right: 1,
              bottom: 1,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: const Color(0xFF34D058),
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.bg, width: 2.5),
                ),
              ),
            ),
        ],
      ),
    );

    final nameStyle = TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 14.5);
    final Widget title = group != null
        ? Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle)
        : StyledName(person: person!, text: '@${person.handle}', style: nameStyle);

    // The preview line: "You: thats why", "@sam: yo", or a camera + "Photo".
    final msg = preview;
    final previewColor = hasUnread ? tokens.ink : tokens.mute;
    final previewStyle = TextStyle(color: previewColor, fontSize: 13, fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400);
    Widget subtitle;
    if (msg == null) {
      subtitle = Text(group != null ? '${group.memberIds.length} people' : 'Say hey 👋', style: previewStyle);
    } else {
      String prefix = '';
      if (msg.uid == 'me') {
        prefix = 'You: ';
      } else if (group != null) {
        final who = store.personById(msg.uid)?.handle;
        if (who != null) prefix = '@$who: ';
      }
      if (msg.mediaType != null) {
        final isVideo = msg.mediaType == 'video';
        subtitle = Row(
          children: [
            if (prefix.isNotEmpty) Text(prefix, style: previewStyle),
            Icon(isVideo ? Icons.videocam_rounded : Icons.photo_camera_rounded, size: 15, color: previewColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                msg.text.isEmpty ? (isVideo ? 'Video' : 'Photo') : msg.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: previewStyle,
              ),
            ),
          ],
        );
      } else {
        subtitle = Text('$prefix${msg.text}', maxLines: 1, overflow: TextOverflow.ellipsis, style: previewStyle);
      }
    }

    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => group != null ? GroupThreadScreen(groupId: group.id) : DmThreadScreen(personId: person!.id),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 2),
                  subtitle,
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(time, style: TextStyle(color: hasUnread ? tokens.brand : tokens.mute, fontSize: 11.5, fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500)),
                const SizedBox(height: 6),
                if (hasUnread)
                  Container(
                    constraints: const BoxConstraints(minWidth: 20),
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(10)),
                    child: Text(unread > 99 ? '99+' : '$unread', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11)),
                  )
                else
                  const SizedBox(height: 20),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConvoEntry {
  final Person? person;
  final GroupChat? group;
  final String room;
  final List<ChatMessage> msgs;
  final int t;
  const _ConvoEntry({this.person, this.group, required this.room, required this.msgs, required this.t});
}

/// "9:41 PM" for today, "Yesterday 11:58 PM" for last night's side of the
/// 2 PM reset — so you can see when each live-chat message was sent.
String _sentAtLabel(BuildContext context, int timestampMs) {
  final sent = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final time = TimeOfDay.fromDateTime(sent).format(context);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final sentDay = DateTime(sent.year, sent.month, sent.day);
  final daysAgo = today.difference(sentDay).inDays;
  if (daysAgo <= 0) return time;
  if (daysAgo == 1) return 'Yesterday $time';
  return '${sent.month}/${sent.day} $time';
}

class _LiveChat extends StatelessWidget {
  const _LiveChat();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    // A banned sender's area-chat messages stop showing up for everyone on
    // this device (see AppStore.banUser) — ghost-mode messages have no uid
    // to check here either way, so they're unaffected.
    final msgs = store.liveChatMessages;

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
        Text('📍 Everyone within ${rangeLabel()} of you, right now', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
        const SizedBox(height: 16),
        if (msgs.isEmpty) Text('Nobody has said anything here tonight. Start it off.', style: TextStyle(color: tokens.mute)),
        ...msgs.map((m) {
          // A guest's own messages go out under their guest name, not the
          // signed-out account's.
          final sender = m.uid == 'me' ? (store.signedIn ? store.me : null) : store.people[m.uid];
          final handle = m.uid == 'me' ? store.myChatHandle : (sender?.handle ?? m.uid);
          Widget nameLine;
          Widget avatar;
          if (m.anon) {
            nameLine = Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12));
            avatar = Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle),
              child: const Text('👻', style: TextStyle(fontSize: 15)),
            );
          } else {
            // Tapping the name goes straight to their profile (your own
            // full profile, for your own messages); tapping the small
            // picture pops up a bigger preview of it first.
            nameLine = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openProfile(context, m.uid),
              child: FunkyHandle(handle: handle, person: sender),
            );
            avatar = sender != null
                ? PersonAvatar(person: sender, size: 30)
                : FunkyAvatar(seed: m.uid, label: handle.isNotEmpty ? handle : '?', size: 30);
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              // Double-tap for a quick ❤️ (toggles it back off if you
              // already reacted with a heart) — hold for the full strip.
              onDoubleTap: () => requireAccountThen(context, store, () => store.toggleReaction(m.id, '❤️')),
              onLongPress: () => _showReactionPicker(context, store, m),
              behavior: HitTestBehavior.opaque,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(child: nameLine),
                      const SizedBox(width: 8),
                      Text(_sentAtLabel(context, m.t), style: TextStyle(color: tokens.mute, fontSize: 11)),
                    ],
                  ),
                  // Roughly how far away they are, small and grey right under
                  // the name (not for your own messages).
                  if (m.uid != 'me' && m.lat != null && m.lng != null && store.location != null)
                    Text(
                      awayLabel(milesBetween(store.location!, LatLng(m.lat!, m.lng!))),
                      style: TextStyle(color: tokens.mute, fontSize: 10.5),
                    ),
                  const SizedBox(height: 2),
                  filteredMessageText(m.text, TextStyle(color: tokens.ink), myHandle: store.me.handle, mentions: true),
                  if (m.uid == 'me' && (m.status == 'sending' || m.status == 'failed'))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: m.status == 'failed' ? () => store.retryChatMessage(m.id) : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.status == 'failed' ? 'Not sent · tap to retry' : 'Sending…',
                              style: TextStyle(color: m.status == 'failed' ? tokens.danger : tokens.mute, fontSize: 11),
                            ),
                            if (m.status == 'failed' && store.sendErrorFor(m.id) != null)
                              Text(store.sendErrorFor(m.id)!, style: TextStyle(color: tokens.mute, fontSize: 10.5)),
                          ],
                        ),
                      ),
                    ),
                  if (m.reactions.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: m.reactions.entries.map((entry) {
                        final mine = entry.value.contains('me');
                        return GestureDetector(
                          onTap: () => requireAccountThen(context, store, () => store.toggleReaction(m.id, entry.key)),
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

/// "Live Chat | Messages" — plain text tabs with a sliding orange line
/// under the one you're on (no box). Messages shows an unread count.
class _ChatTabs extends StatelessWidget {
  final int index;
  final int unread;
  final ValueChanged<int> onTap;
  const _ChatTabs({required this.index, required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    Widget tab(int i, String label) {
      final active = index == i;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(i),
          child: SizedBox(
            height: 42,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 160),
                    style: TextStyle(
                      color: active ? tokens.ink : tokens.mute,
                      fontSize: 15,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    ),
                    child: Text(label),
                  ),
                  if (i == 1 && unread > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(10)),
                      child: Text(unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Stack(
        children: [
          // A hairline under both tabs…
          Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 1, color: tokens.line)),
          Column(
            children: [
              Row(children: [tab(0, 'Live Chat'), tab(1, 'Messages')]),
              // …and the orange line that slides to the active one.
              AnimatedAlign(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: index == 0 ? Alignment.centerLeft : Alignment.centerRight,
                child: FractionallySizedBox(
                  widthFactor: 0.5,
                  child: Center(
                    child: Container(
                      width: 84,
                      height: 2.5,
                      decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
