import '../widgets/ios_ui.dart';
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
import '../widgets/gif_picker.dart';
import '../widgets/kind_picker.dart';
import '../data/when_labels.dart';
import 'create_sheet.dart';
import 'live_chat_view.dart';

/// The pop-up shown the moment you flip on ghost mode in Live Chat — the
/// only place anonymous mode lives now (it used to also be a switch on the
/// profile page, which made it unclear what it actually covered).
void _showAnonymousDialog(BuildContext context) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  showIosDialog<void>(
    context: context,
    builder: (dialogContext) => IosAlert(
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
  // The message you're answering (swipe right on it, or hold → Reply).
  ChatMessage? _replyTo;
  final _focus = FocusNode();

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
    _focus.dispose();
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

  void _startReply(ChatMessage m) {
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  /// Sends what's typed, plus a spot, poll or GIF if one was picked.
  void _send(AppStore store, {String? placeId, String? pollId, String? gifUrl}) {
    final text = _draftController.text.trim();
    if (text.isEmpty && placeId == null && pollId == null && gifUrl == null) return;
    void go() {
      // No account: always anonymous.
      final anon = _anon || !store.signedIn;
      final error = store.sendMessage('main', text, anon, replyTo: _replyTo, placeId: placeId, pollId: pollId, gifUrl: gifUrl);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        return;
      }
      _draftController.clear();
      setState(() => _replyTo = null);
    }

    // Reading the live chat never needs an account, and a guest can chat
    // (anonymously) too.
    if (_anon || store.signedIn || store.isGuest) {
      go();
    } else {
      requireGuestOkThen(context, store, go);
    }
  }

  Future<void> _shareSpot(AppStore store) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final tonight = [...store.rankedPlaces];
    final soon = store.upcomingPlaces;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.65,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                child: Text('Share a spot', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              if (tonight.isEmpty && soon.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text('No spots listed near you yet.', style: TextStyle(color: tokens.mute)),
                ),
              for (final p in tonight.take(40))
                ListTile(
                  onTap: () => Navigator.of(sheetContext).pop(p.id),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: PlaceMediaThumbnail(
                        story: null,
                        coverPhotoPath: p.coverPhotoPath,
                        coverUrl: p.coverUrl,
                        photoUrl: p.photoUrl,
                        fallbackLabel: p.name.isNotEmpty ? p.name.substring(0, 1) : '?',
                        fontSize: 16,
                      ),
                    ),
                  ),
                  title: Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    '${placeKindLabel(p.kind)} · ${p.going > 0 ? '🔥 ${p.going} going · ' : ''}${formatMiles(p.distance)}',
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                ),
              if (soon.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                  child: Text('Coming up', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              for (final p in soon.take(20))
                ListTile(
                  onTap: () => Navigator.of(sheetContext).pop(p.id),
                  leading: Icon(Icons.event_rounded, color: tokens.brand),
                  title: Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    p.place.shownTime == null ? '${dayLabel(p.place.startsAt!)}${p.place.isPrivate ? ' · 🔒 Private' : ''}' : whenLabel(p.place.startsAt!),
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _send(store, placeId: picked);
  }

  Future<void> _startPoll(AppStore store) async {
    await requireAccountThen(context, store, () async {
      final before = DateTime.now().millisecondsSinceEpoch - 1000;
      await showCreateSheet(context, initial: CreateKind.poll);
      if (!mounted) return;
      // Share the poll you just made straight into the chat.
      final mine = store.polls.where((p) => p.by == 'me' && p.t >= before).toList();
      if (mine.isNotEmpty) _send(store, pollId: mine.last.id);
    });
  }

  Future<void> _sharePoll(AppStore store) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final polls = store.rankedVisiblePolls;
    final canMake = !store.signedIn || store.canAddPollToday;
    if (polls.isEmpty) {
      // Nothing to share yet: go straight to making one.
      if (canMake) {
        await _startPoll(store);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No polls around here yet, and you've already made your poll for today.")),
        );
      }
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                child: Text('Polls', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              if (canMake)
                ListTile(
                  onTap: () => Navigator.of(sheetContext).pop('__new__'),
                  leading: Icon(Icons.add_chart_rounded, color: tokens.brand),
                  title: Text('Start a new poll', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                  subtitle: Text('One a day. It goes in the chat when you post it.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                ),
              if (polls.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Text('Share one from around here', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              for (final poll in polls.take(30))
                ListTile(
                  onTap: () => Navigator.of(sheetContext).pop(poll.id),
                  leading: Icon(Icons.poll_outlined, color: tokens.ink),
                  title: Text(maskBadWords(poll.q), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    () {
                      final n = store.pollCounts(poll).fold<int>(0, (a, b) => a + b);
                      return n == 1 ? '1 vote' : '$n votes';
                    }(),
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == '__new__') {
      await _startPoll(store);
    } else {
      _send(store, pollId: picked);
    }
  }

  Future<void> _pickGif(AppStore store) async {
    final url = await showGifPicker(context, store);
    if (url == null || !mounted) return;
    _send(store, gifUrl: url);
  }

  void _toggleAnon(AppStore store) {
    if (!store.signedIn) {
      Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const AccountScreen(closeOnSuccess: true)));
      return;
    }
    final turningOn = !_anon;
    setState(() => _anon = turningOn);
    if (turningOn) _showAnonymousDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final live = _segment == 0 && store.location != null;
    final anon = _anon || !store.signedIn;
    final reply = _replyTo;

    Widget chip(String label, IconData icon, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: tokens.raised,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: tokens.ink),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12)),
                ],
              ),
            ),
          ),
        );

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
                      : LiveChatView(onReply: _startReply),
            ),
            if (live && _mentionSuggestions.isNotEmpty)
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
            if (live)
              Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                decoration: BoxDecoration(color: tokens.bg, border: Border(top: BorderSide(color: tokens.line, width: 0.5))),
                child: SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (reply != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                          decoration: BoxDecoration(
                            color: tokens.raised,
                            borderRadius: BorderRadius.circular(12),
                            border: Border(left: BorderSide(color: tokens.brand, width: 3)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Replying to ${reply.anon ? 'anonymous' : '@${store.chatHandleFor(reply)}'}',
                                      style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 12.5),
                                    ),
                                    Text(
                                      reply.text.trim().isNotEmpty ? maskBadWords(reply.text) : (reply.gifUrl != null ? 'GIF' : (reply.sharedPlaceId != null ? 'Shared a spot' : 'Shared a poll')),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: tokens.mute, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => setState(() => _replyTo = null),
                                icon: Icon(Icons.close_rounded, color: tokens.mute, size: 20),
                              ),
                            ],
                          ),
                        )
                      else
                        SizedBox(
                          height: 28,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              chip('Share a spot', Icons.place_outlined, () => _shareSpot(store)),
                              chip('Share a poll', Icons.poll_outlined, () => _sharePoll(store)),
                            ],
                          ),
                        ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleAnon(store),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 4, top: 1),
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  !store.signedIn
                                      ? 'Posting as 👻 anonymous · make an account to use your name'
                                      : (anon ? 'Posting as 👻 anonymous' : 'Posting as @${store.myChatHandle}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: tokens.mute, fontSize: 11.5, fontWeight: FontWeight.w600),
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: tokens.mute, size: 18),
                            ],
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _draftController,
                              focusNode: _focus,
                              maxLength: 240,
                              minLines: 1,
                              maxLines: 4,
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(color: tokens.ink, fontSize: 15),
                              decoration: InputDecoration(
                                hintText: 'Message ${store.areaName ?? 'everyone nearby'}…',
                                hintStyle: TextStyle(color: tokens.mute),
                                filled: true,
                                fillColor: tokens.raised,
                                counterText: '',
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                suffixIcon: store.giphyKey != null || store.isAdmin
                                    ? IconButton(
                                        onPressed: () => _pickGif(store),
                                        icon: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(border: Border.all(color: tokens.mute, width: 1.3), borderRadius: BorderRadius.circular(5)),
                                          child: Text('GIF', style: TextStyle(color: tokens.mute, fontSize: 10.5, fontWeight: FontWeight.w900)),
                                        ),
                                      )
                                    : null,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                              ),
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
                              child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 20),
                            ),
                          ),
                        ],
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
      if (msg.gifUrl != null && msg.text.isEmpty) {
        subtitle = Row(
          children: [
            if (prefix.isNotEmpty) Text(prefix, style: previewStyle),
            Icon(Icons.gif_box_outlined, size: 16, color: previewColor),
            const SizedBox(width: 6),
            Text('GIF', style: previewStyle),
          ],
        );
      } else if (msg.mediaType != null) {
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
      } else if (msg.isStoryReply) {
        final who = msg.uid == 'me' ? 'You replied to their story' : 'Replied to your story';
        subtitle = Row(
          children: [
            Icon(Icons.reply_rounded, size: 15, color: previewColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                msg.text.isEmpty ? who : '$who: ${msg.text}',
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
