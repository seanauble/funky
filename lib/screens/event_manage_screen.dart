import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../data/when_labels.dart';
import '../services/address_search.dart';
import '../services/share_links.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/chat_cards.dart';
import '../widgets/ios_ui.dart';
import '../widgets/ui_widgets.dart';
import 'dm_thread_screen.dart';
import 'payment_apps_screen.dart';

/// Running a party: requests to go, codes, the door, and the team.
/// Door staff only get the Door tab.
class EventManageScreen extends StatefulWidget {
  final String placeId;
  // 0 requests, 1 codes, 2 door, 3 team (for hosts and co-hosts).
  final int initialTab;
  const EventManageScreen({super.key, required this.placeId, this.initialTab = 0});

  @override
  State<EventManageScreen> createState() => _EventManageScreenState();
}

class _EventManageScreenState extends State<EventManageScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    // Requests and check-ins move fast on the night.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final p = _place(store);
    if (p == null) return;
    await Future.wait([
      store.fetchEventGuests(p.id),
      if (store.canManageEvent(p)) store.fetchEventRequests(p.id),
      if (store.canManageEvent(p)) store.fetchEventCodes(p.id),
    ]);
  }

  Place? _place(AppStore store) {
    for (final p in store.places) {
      if (p.id == widget.placeId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final p = _place(store);
    if (p == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: const Center(child: EmptyNote(text: "This event isn't around anymore.")),
      );
    }
    final manage = store.canManageEvent(p);
    final open = store.openRequestCount(p.id);
    final tabs = manage
        ? [
            Tab(text: open > 0 ? 'Requests ($open)' : 'Requests'),
            const Tab(text: 'Codes'),
            const Tab(text: 'Door'),
            const Tab(text: 'Team'),
          ]
        : const [Tab(text: 'Door')];
    final views = manage
        ? [_RequestsTab(place: p), _CodesTab(place: p), _DoorTab(place: p), _TeamTab(place: p)]
        : [_DoorTab(place: p)];
    final role = store.eventRole(p);
    return DefaultTabController(
      length: tabs.length,
      initialIndex: manage ? widget.initialTab.clamp(0, 3) : 0,
      child: Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(
          backgroundColor: tokens.bg,
          foregroundColor: tokens.ink,
          elevation: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
              Text(
                role == 'host' ? 'You\'re the host' : role == 'cohost' ? 'You\'re a co-host' : 'You\'re on the door',
                style: TextStyle(color: tokens.mute, fontSize: 12),
              ),
            ],
          ),
          actions: [
            if (manage)
              TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventEditScreen(placeId: p.id))),
                child: Text('Edit', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
              ),
          ],
          bottom: TabBar(
            isScrollable: false,
            labelColor: tokens.ink,
            unselectedLabelColor: tokens.mute,
            indicatorColor: tokens.brand,
            labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
            tabs: tabs,
          ),
        ),
        body: TabBarView(children: views),
      ),
    );
  }
}

Widget _avatarFor(AppStore store, String uid, {double size = 42}) {
  final person = uid == 'me' ? store.me : store.personById(uid);
  return person != null ? PersonAvatar(person: person, size: size, preview: false) : FunkyAvatar(seed: uid, label: '?', size: size);
}

String _handle(AppStore store, String uid) => uid == 'me' ? store.me.handle : (store.personById(uid)?.handle ?? 'someone');

// ---- Requests -------------------------------------------------------------------

class _RequestsTab extends StatelessWidget {
  final Place place;
  const _RequestsTab({required this.place});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final reqs = [...store.eventRequests(place.id)];
    const rank = {'paid': 0, 'pay_sent': 1, 'asked': 2, 'in': 3, 'declined': 4};
    reqs.sort((a, b) {
      final r = (rank[a.status] ?? 5).compareTo(rank[b.status] ?? 5);
      return r != 0 ? r : b.updatedAt.compareTo(a.updatedAt);
    });
    return RefreshIndicator(
      onRefresh: () => store.fetchEventRequests(place.id),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
        children: [
          if (store.payHandles.isEmpty)
            FunkyCard(
              margin: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentAppsScreen())),
                child: Row(
                  children: [
                    Icon(Icons.attach_money_rounded, color: tokens.friend),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Add your Venmo or Cash App so "Send my Venmo" works in one tap.',
                          style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    Icon(Icons.chevron_right_rounded, color: tokens.mute),
                  ],
                ),
              ),
            ),
          Text(
            'People who tap "Ask to go" on your event or flyer story show up here and in your messages. '
            'Send your Venmo, check it came through, then let them in.',
            style: TextStyle(color: tokens.mute, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 10),
          if (reqs.isEmpty) const EmptyNote(text: 'No requests yet. Post your flyer as a story at the event so people can ask.'),
          for (final r in reqs) _RequestRow(place: place, req: r),
        ],
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  final Place place;
  final EventRequest req;
  const _RequestRow({required this.place, required this.req});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.read<AppStore>();
    final (label, color) = switch (req.status) {
      'pay_sent' => ('Payment sent · waiting on them', tokens.mute),
      'paid' => ('Says they paid — check your app', tokens.orange),
      'in' => ("In ✓${req.handledBy != null ? ' · by @${_handle(store, req.handledBy!)}' : ''}", tokens.friend),
      'declined' => ('Said no', tokens.mute),
      _ => ('Asked to go', tokens.brand),
    };
    final open = const {'asked', 'pay_sent', 'paid'}.contains(req.status);
    Widget small(String text, VoidCallback onTap, {bool primary = false}) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: SizedBox(
            height: 34,
            child: primary
                ? ElevatedButton(
                    onPressed: onTap,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tokens.brand,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(text, style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 12.5)),
                  )
                : OutlinedButton(
                    onPressed: onTap,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: tokens.line),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(text, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 12.5)),
                  ),
          ),
        );
    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(onTap: () => openProfile(context, req.uid), child: _avatarFor(store, req.uid)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@${_handle(store, req.uid)}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                    Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Message',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: req.uid))),
                icon: Icon(Icons.chat_bubble_outline_rounded, color: tokens.ink, size: 21),
              ),
            ],
          ),
          if ((req.note ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 52),
              child: Text('"${req.note}"', style: TextStyle(color: tokens.ink, fontSize: 13.5)),
            ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  small('No', () async {
                    final ok = await showIosActionSheet<bool>(
                      context,
                      message: "Tell @${_handle(store, req.uid)} you can't fit them in?",
                      actions: const [IosSheetAction("Can't fit them in", true, destructive: true)],
                    );
                    if (ok != true) return;
                    final err = await store.declineEventRequest(place.id, req.uid);
                    if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                  }),
                  if (req.status == 'asked')
                    small('Send my Venmo', () async {
                      final err = await store.sendEventPayCard(place.id, req.uid);
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Sent them how to pay.')));
                    }),
                  small('Let in', () => letInWithConfirm(context, store, place, req.uid), primary: true),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Codes --------------------------------------------------------------------------

class _CodesTab extends StatelessWidget {
  final Place place;
  const _CodesTab({required this.place});

  Future<void> _make(BuildContext context, AppStore store) async {
    final label = TextEditingController();
    var count = 1;
    final go = await showIosDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => IosAlert(
          title: const Text('Make codes'),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Each code gets one person in, once. Send one to each person who paid.'),
                const SizedBox(height: 10),
                CupertinoSlidingSegmentedControl<int>(
                  groupValue: count,
                  children: const {1: Text('1'), 5: Text('5'), 10: Text('10'), 25: Text('25')},
                  onValueChanged: (v) => setD(() => count = v ?? 1),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: label,
                  maxLength: 40,
                  decoration: InputDecoration(
                    hintText: count == 1 ? "Who's it for? (optional)" : 'Label, like "Mike\'s list" (optional)',
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Make')),
          ],
        ),
      ),
    );
    final text = label.text.trim();
    label.dispose();
    if (go != true || !context.mounted) return;
    final (made, err) = await store.makeEventCodes(place.id, count, label: text.isEmpty ? null : text);
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (made.length == 1) await shareFunkyEventCode(context, place.name, made.first.code, who: made.first.label);
  }

  Future<void> _switchMode(BuildContext context, AppStore store, PrivateEventDetails d) async {
    if (!d.personalCodes) {
      final ok = await showIosDialog<bool>(
        context: context,
        builder: (ctx) => IosAlert(
          title: const Text('A code for each person?'),
          content: const Text("Your shared code stops working. Everyone who's already in stays in. Then make a code for each person."),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Switch')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      final err = await store.updateEvent(place, {'code_mode': 'personal'});
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Switched — make a code for each person.')));
      return;
    }
    final field = TextEditingController();
    final code = await showIosDialog<String>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text('One code for everyone'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Pick the code. Personal codes you already sent keep working.'),
              const SizedBox(height: 10),
              TextField(
                controller: field,
                autofocus: true,
                maxLength: 20,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(hintText: 'CODE', counterText: '', isDense: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Use it')),
        ],
      ),
    );
    field.dispose();
    if (code == null || !context.mounted) return;
    final err = await store.updateEvent(place, {'code_mode': 'shared', 'passcode': code.trim()});
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Everyone can use ${code.trim()} now.')));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final d = store.privateDetailsFor(place.id);
    final codes = store.eventCodes(place.id);
    final used = codes.where((c) => c.used).length;
    if (!place.isPrivate || d == null) {
      return const Padding(padding: EdgeInsets.all(20), child: EmptyNote(text: 'Codes are for private events.'));
    }
    return RefreshIndicator(
      onRefresh: () => store.fetchEventCodes(place.id),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
        children: [
          FunkyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.personalCodes ? 'A CODE FOR EACH PERSON' : 'ONE CODE FOR EVERYONE',
                    style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w900, fontSize: 11.5, letterSpacing: 0.6)),
                const SizedBox(height: 6),
                if (!d.personalCodes && d.passcode != null)
                  Row(
                    children: [
                      Expanded(child: Text(d.passcode!, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 24, letterSpacing: 3))),
                      IconButton(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: d.passcode!));
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied.')));
                        },
                        icon: Icon(Icons.copy_rounded, color: tokens.ink),
                      ),
                      IconButton(
                        onPressed: () => shareFunkyPlace(context, place.name, when: place.startsAt == null ? null : dayLabel(place.startsAt!), code: d.passcode),
                        icon: Icon(Icons.ios_share_rounded, color: tokens.ink),
                      ),
                    ],
                  )
                else
                  Text('Each code works once, so passing it on gets nobody else in.', style: TextStyle(color: tokens.ink, fontSize: 13.5)),
                const SizedBox(height: 4),
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  onPressed: () => _switchMode(context, store, d),
                  child: Text(d.personalCodes ? 'Switch to one code for everyone' : 'Switch to a code for each person',
                      style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _make(context, store),
              icon: Icon(Icons.add_rounded, color: tokens.onOrange),
              label: Text('Make codes', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          if (codes.isNotEmpty) ...[
            SectionHeader(title: '${codes.length} codes · $used used'),
            for (final c in codes)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: tokens.line)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(c.code,
                                  style: TextStyle(
                                    color: c.used ? tokens.mute : tokens.ink,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 17,
                                    letterSpacing: 2,
                                    decoration: c.used ? TextDecoration.lineThrough : null,
                                  )),
                              if ((c.label ?? '').isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Flexible(child: Text(c.label!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700))),
                              ],
                            ],
                          ),
                          Text(
                            c.used
                                ? 'Used by @${_handle(store, c.usedBy!)}${c.usedAt != null ? ' · ${clockLabel(c.usedAt!)}' : ''}'
                                    '${c.createdBy != null ? ' · made by ${c.createdBy == 'me' ? 'you' : '@${_handle(store, c.createdBy!)}'}' : ''}'
                                : 'Not used yet${c.createdBy != null ? ' · made by ${c.createdBy == 'me' ? 'you' : '@${_handle(store, c.createdBy!)}'}' : ''}',
                            style: TextStyle(color: c.used ? tokens.friend : tokens.mute, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (!c.used) ...[
                      IconButton(
                        tooltip: 'Send',
                        onPressed: () => shareFunkyEventCode(context, place.name, c.code, who: c.label),
                        icon: Icon(Icons.ios_share_rounded, color: tokens.ink, size: 20),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () async {
                          final err = await store.deleteEventCode(c);
                          if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                        },
                        icon: Icon(Icons.delete_outline_rounded, color: tokens.danger, size: 20),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---- Door -------------------------------------------------------------------------------

class _DoorTab extends StatefulWidget {
  final Place place;
  const _DoorTab({required this.place});

  @override
  State<_DoorTab> createState() => _DoorTabState();
}

class _DoorTabState extends State<_DoorTab> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _checkIn(AppStore store, EventGuest g) async {
    final handle = _handle(store, g.uid);
    if (g.checkedInAt != null) {
      final undo = await showIosActionSheet<bool>(
        context,
        message: '@$handle was checked in at ${clockLabel(g.checkedInAt!)}.',
        actions: const [IosSheetAction('Undo check-in', true, destructive: true)],
      );
      if (undo != true) return;
      final (_, _, err) = await store.checkInGuest(widget.place.id, g.uid, undo: true);
      if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final (at, already, err) = await store.checkInGuest(widget.place.id, g.uid);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (already) {
      HapticFeedback.heavyImpact();
      await showIosDialog<void>(
        context: context,
        builder: (ctx) => IosAlert(
          title: const Text('Already checked in'),
          content: Text('@$handle got in at ${at == null ? 'earlier' : clockLabel(at)}. Each person gets in once.'),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
        ),
      );
      unawaited(store.fetchEventGuests(widget.place.id));
      return;
    }
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final q = _search.text.trim().toLowerCase().replaceFirst('@', '');
    final all = store.eventGuests(widget.place.id).where((g) => g.status != 'cant').toList();
    final inCount = all.where((g) => g.checkedInAt != null).length;
    final list = all.where((g) => q.isEmpty || _handle(store, g.uid).toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        final ai = a.checkedInAt != null ? 1 : 0;
        final bi = b.checkedInAt != null ? 1 : 0;
        if (ai != bi) return ai.compareTo(bi);
        return _handle(store, a.uid).toLowerCase().compareTo(_handle(store, b.uid).toLowerCase());
      });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  autocorrect: false,
                  style: TextStyle(color: tokens.ink),
                  decoration: InputDecoration(
                    hintText: 'Search the list',
                    hintStyle: TextStyle(color: tokens.mute),
                    prefixIcon: Icon(Icons.search_rounded, color: tokens.mute),
                    isDense: true,
                    filled: true,
                    fillColor: tokens.raised,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                children: [
                  Text('$inCount/${all.length}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 18)),
                  Text('in', style: TextStyle(color: tokens.mute, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Match their face to their pass, then tap Check in.', style: TextStyle(color: tokens.mute, fontSize: 12)),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => store.fetchEventGuests(widget.place.id),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 30),
              itemCount: list.isEmpty ? 1 : list.length,
              itemBuilder: (context, i) {
                if (list.isEmpty) return const Padding(padding: EdgeInsets.all(20), child: EmptyNote(text: 'Nobody on the list yet.'));
                final g = list[i];
                final done = g.checkedInAt != null;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _avatarFor(store, g.uid, size: 52),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(g.uid == 'me' ? 'You' : '@${_handle(store, g.uid)}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                            Text(
                              done ? 'In at ${clockLabel(g.checkedInAt!)}' : (g.status == 'going' ? 'Going' : g.status == 'maybe' ? 'Maybe' : 'Has the code'),
                              style: TextStyle(color: done ? tokens.friend : tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 38,
                        child: done
                            ? OutlinedButton(
                                onPressed: () => _checkIn(store, g),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: tokens.friend),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                                ),
                                child: Text('✓ In', style: TextStyle(color: tokens.friend, fontWeight: FontWeight.w900)),
                              )
                            : ElevatedButton(
                                onPressed: () => _checkIn(store, g),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: tokens.brand,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                                ),
                                child: Text('Check in', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w900)),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ---- Team ------------------------------------------------------------------------------

class _TeamTab extends StatelessWidget {
  final Place place;
  const _TeamTab({required this.place});

  Future<void> _add(BuildContext context, AppStore store) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final team = store.eventTeam(place.id);
    final candidates = <String>{
      ...store.me.friends,
      for (final g in store.eventGuests(place.id)) if (g.uid != 'me') g.uid,
    }..removeWhere((u) => team.containsKey(u) || u == place.by || u == 'me');
    final people = [for (final u in candidates) if (store.personById(u) case final p?) p]
      ..sort((a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()));
    if (people.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add them as a friend first, or let them in — then you can add them here.')));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tokens.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Text('Add to the team', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 18)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text('Your friends and people on the list.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in people)
                      ListTile(
                        leading: PersonAvatar(person: p, size: 38, preview: false),
                        title: Text('@${p.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                        onTap: () => Navigator.of(ctx).pop(p.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    await _pickRole(context, store, picked);
  }

  Future<void> _pickRole(BuildContext context, AppStore store, String uid, {bool existing = false}) async {
    final role = await showIosActionSheet<String>(
      context,
      title: '@${_handle(store, uid)}',
      message: 'Co-hosts can change the details, make codes and let people in. Door staff can only check people in.',
      actions: [
        const IosSheetAction('Co-host', 'cohost', icon: Icons.star_outline_rounded),
        const IosSheetAction('Door', 'door', icon: Icons.door_front_door_outlined),
        if (existing) const IosSheetAction('Take off the team', '', destructive: true, icon: Icons.person_remove_outlined),
      ],
    );
    if (role == null || !context.mounted) return;
    final err = await store.setEventRole(place.id, uid, role.isEmpty ? null : role);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err ?? (role.isEmpty ? 'Taken off the team.' : '@${_handle(store, uid)} is ${role == 'cohost' ? 'a co-host' : 'on the door'} now.')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final team = store.eventTeam(place.id);
    final isHost = place.by == 'me' || store.isAdmin;
    Widget row(String uid, String role) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: _avatarFor(store, uid, size: 42),
          title: Text(uid == 'me' ? 'You' : '@${_handle(store, uid)}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
          subtitle: Text(
            role == 'host' ? 'Host' : role == 'cohost' ? 'Co-host · details, codes, letting people in' : 'Door · checks people in',
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
          trailing: isHost && role != 'host' ? Icon(Icons.more_horiz_rounded, color: tokens.mute) : null,
          onTap: isHost && role != 'host' ? () => _pickRole(context, store, uid, existing: true) : null,
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        row(place.by, 'host'),
        for (final e in team.entries.where((e) => e.value == 'cohost')) row(e.key, 'cohost'),
        for (final e in team.entries.where((e) => e.value == 'door')) row(e.key, 'door'),
        const SizedBox(height: 12),
        if (isHost)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _add(context, store),
              icon: Icon(Icons.person_add_alt_1_outlined, color: tokens.ink),
              label: Text('Add a co-host or door', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: tokens.line),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          )
        else
          Text('Only the host can change the team.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
      ],
    );
  }
}

// ---- Edit ---------------------------------------------------------------------------------

/// Change an event's name, time, address, price and who sees the count.
class EventEditScreen extends StatefulWidget {
  final String placeId;
  const EventEditScreen({super.key, required this.placeId});

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _price;
  DateTime? _start;
  bool _hide = false;
  bool _busy = false;
  Place? _p;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    for (final x in store.places) {
      if (x.id == widget.placeId) _p = x;
    }
    final p = _p;
    final d = store.privateDetailsFor(widget.placeId);
    _name = TextEditingController(text: p?.name ?? '');
    final addr = p?.isPrivate == true ? (d?.address ?? '') : (p?.address ?? '');
    _address = TextEditingController(text: addr == 'Address not given' || addr == 'Private event' ? '' : addr);
    final price = p?.entryPrice;
    _price = TextEditingController(text: price == null ? '' : (price == price.roundToDouble() ? '${price.round()}' : price.toStringAsFixed(2)));
    _start = p?.isPrivate == true ? (d?.startsAt ?? p?.startsAt) : p?.startsAt;
    _hide = p?.hidesGoingCount ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = _p;
    if (p == null || _busy) return;
    final store = context.read<AppStore>();
    final changes = <String, dynamic>{};
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give it a name.')));
      return;
    }
    if (name != p.name) changes['name'] = name;
    final priceText = _price.text.trim().replaceAll(r'$', '');
    final currentPrice = p.entryPrice;
    final newPrice = priceText.isEmpty ? null : double.tryParse(priceText);
    if (priceText.isNotEmpty && newPrice == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Type the price as a number, like 10.')));
      return;
    }
    if (newPrice != currentPrice) changes['price'] = newPrice == null ? '' : newPrice.toStringAsFixed(2);
    if (_hide != p.hidesGoingCount) changes['going_visibility'] = _hide ? 'hint' : 'public';
    final start = _start;
    final d = store.privateDetailsFor(p.id);
    final oldStart = p.isPrivate ? (d?.startsAt ?? p.startsAt) : p.startsAt;
    if (start != null && start != oldStart) changes['starts_at'] = start;
    final addr = _address.text.trim();
    final oldAddr = p.isPrivate ? (d?.address ?? '') : p.address;
    setState(() => _busy = true);
    if (addr.isNotEmpty && addr != oldAddr) {
      changes['address'] = addr;
      final here = store.location;
      try {
        final found = await AddressSearch.search(addr, nearLat: here?.lat, nearLng: here?.lng);
        if (found.isNotEmpty) {
          changes['lat'] = found.first.lat;
          changes['lng'] = found.first.lng;
        }
      } catch (_) {}
    }
    if (changes.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final err = await store.updateEvent(p, changes);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved.')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final p = _p;
    InputDecoration deco(String label, {String? prefix}) => InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: tokens.mute),
          prefixText: prefix,
          filled: true,
          fillColor: tokens.raised,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: const Text('Edit event'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving…' : 'Save', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
      body: p == null
          ? const Center(child: EmptyNote(text: "This event isn't around anymore."))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(controller: _name, maxLength: 60, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700), decoration: deco('Name')),
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showIosDateTimePicker(
                      context,
                      initial: _start ?? now.add(const Duration(hours: 2)),
                      minimum: now.subtract(const Duration(hours: 6)),
                      maximum: now.add(const Duration(days: 60)),
                      title: 'When does it start?',
                    );
                    if (picked != null) setState(() => _start = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        Icon(Icons.schedule_rounded, color: tokens.ink),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _start == null ? 'Start time' : '${dayLabel(_start!)} · ${clockLabel(_start!)}',
                            style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: tokens.mute),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _address,
                  maxLength: 120,
                  style: TextStyle(color: tokens.ink),
                  decoration: deco(p.isPrivate ? 'Address (only guests see it)' : 'Address'),
                ),
                if (p.isPrivate) ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                    decoration: deco('Price to get in (optional)', prefix: r'$ '),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Only hosts see how many are going', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                              Text(
                                _hide ? 'Everyone else sees a few faces going, no number.' : 'Everyone with the code sees the count and the list.',
                                style: TextStyle(color: tokens.mute, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(value: _hide, activeTrackColor: tokens.brand, onChanged: (v) => setState(() => _hide = v)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
