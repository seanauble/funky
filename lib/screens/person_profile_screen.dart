import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import 'account_screen.dart';
import '../widgets/rainbow_ring.dart';
import '../data/models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'admin_manage_user_screen.dart';
import 'dm_thread_screen.dart';
import 'profile_parts.dart';
import '../services/share_links.dart';
import '../root_shell.dart' show rootShellTabRequest;
import 'story_viewer_screen.dart';

/// Pick a reason, send the report to the FUNKY team.
Future<void> _reportProfile(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Text('Report @$handle', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          for (final r in AppStore.profileReportReasons)
            ListTile(
              title: Text(r, style: TextStyle(color: tokens.ink)),
              onTap: () => Navigator.of(sheetContext).pop(r),
            ),
        ],
        ),
      ),
    ),
  );
  if (reason == null || !context.mounted) return;
  final message = await store.reportProfile(personId, reason);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Someone else's profile: big picture, name, bio and title, their
/// numbers, Add friend / Message, then their Memories and Places in tabs.
class PersonProfileScreen extends StatefulWidget {
  final String personId;
  const PersonProfileScreen({super.key, required this.personId});

  @override
  State<PersonProfileScreen> createState() => _PersonProfileScreenState();
}

class _PersonProfileScreenState extends State<PersonProfileScreen> {
  int _tab = 0; // 0 = Memories, 1 = Places

  String get personId => widget.personId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().loadFriendCount(personId);
    });
  }

  Future<void> _moreMenu(AppStore store, Person person) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final isFriend = store.isFriendsWith(personId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: tokens.line, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 6),
            ListTile(
              leading: Icon(Icons.ios_share, color: tokens.ink),
              title: Text('Share profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.of(sheetContext).pop('share'),
            ),
            if (isFriend)
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: tokens.danger),
                title: Text('Remove friend', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
            if (store.signedIn)
              ListTile(
                leading: Icon(Icons.flag_outlined, color: tokens.ink),
                title: Text('Report this profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.of(sheetContext).pop('report'),
              ),
            // Admin tools live on their own screen, never on the profile.
            if (store.isAdmin)
              ListTile(
                leading: Icon(Icons.admin_panel_settings_outlined, color: tokens.gold),
                title: Text('Manage this account (Admin)', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(sheetContext).pop('admin'),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'share':
        await shareFunkyProfile(context, person.handle);
      case 'remove':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            backgroundColor: tokens.surface,
            title: Text('Remove @${person.handle}?', style: TextStyle(color: tokens.ink)),
            content: Text("You'll stop seeing each other's memories.", style: TextStyle(color: tokens.mute)),
            actions: [
              TextButton(onPressed: () => Navigator.of(d).pop(false), child: Text('Cancel', style: TextStyle(color: tokens.mute))),
              TextButton(onPressed: () => Navigator.of(d).pop(true), child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700))),
            ],
          ),
        );
        if (ok == true) store.removeFriend(personId);
      case 'report':
        await _reportProfile(context, store, personId, person.handle);
      case 'admin':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AdminManageUserScreen(personId: personId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(personId);

    if (person == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This person isn't around anymore tonight.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final isSelf = personId == 'me';
    final isFriend = store.isFriendsWith(personId);
    final requestSent = store.hasSentRequestTo(personId);
    final requestReceived = store.hasRequestFrom(personId);
    final banned = store.isBanned(personId);
    // Memories: everything for a friend, only tonight's for anyone else.
    // Anonymous posts never show here — that would give away who posted them.
    final memories = banned ? const <Story>[] : store.visibleStoriesByUser(personId).where((s) => !s.anon).toList();
    final places = memoryPlacesFrom(memories, store);
    final title = levelTitleFor(person.points);
    final friendCount = isSelf ? store.me.friends.length : store.friendCounts[personId];

    // The story ring around their picture: their last 24 hours.
    final ringStories = store.liveStoriesByUser(personId).where((s) => !s.anon).toList();
    final hasRing = ringStories.isNotEmpty && !banned;
    final ringUnseen = ringStories.any((s) => !s.views.contains('me'));

    const avatarSize = 100.0;
    final avatar = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: hasRing
          ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: [personId])))
          : () => showAvatarPreview(context, person, viewProfile: false),
      onLongPress: () => showAvatarPreview(context, person, viewProfile: false),
      child: hasRing && ringUnseen
          ? RainbowRing(size: avatarSize + 10, strokeWidth: 4, child: PersonAvatar(person: person, size: avatarSize - 6, preview: false))
          : Container(
              width: avatarSize + 10,
              height: avatarSize + 10,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.line, width: 3)),
              child: PersonAvatar(person: person, size: avatarSize - 6, preview: false),
            ),
    );

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        centerTitle: true,
        title: Text('@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
        actions: [
          Builder(
            builder: (c) => IconButton(
              tooltip: 'Share profile',
              icon: Icon(Icons.ios_share, color: tokens.ink),
              onPressed: () => shareFunkyProfile(c, person.handle),
            ),
          ),
          if (!isSelf)
            IconButton(
              tooltip: 'More',
              icon: Icon(Icons.more_horiz, color: tokens.ink),
              onPressed: () => _moreMenu(store, person),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(child: avatar),
          const SizedBox(height: 12),
          Center(
            child: StyledName(
              person: person,
              text: '@${person.handle}',
              style: TextStyle(color: tokens.ink, fontSize: 21, fontWeight: FontWeight.w800),
            ),
          ),
          if (person.bio.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(person.bio, textAlign: TextAlign.center, style: TextStyle(color: tokens.mute, fontSize: 13.5)),
          ],
          if (title != null) ...[
            const SizedBox(height: 8),
            Center(child: ProfileTitleChip(title: title)),
          ],
          if (banned) ...[
            const SizedBox(height: 8),
            Text('This account is banned.', textAlign: TextAlign.center, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 14),
          ProfileStatsRow(stats: [
            (formatCount(memories.length), 'Memories', () => setState(() => _tab = 0)),
            (friendCount == null ? '–' : formatCount(friendCount), 'Friends', null),
            (formatCount(places.length), 'Places', () => setState(() => _tab = 1)),
          ]),
          const SizedBox(height: 16),
          if (!isSelf)
            _FriendButtons(
              isFriend: isFriend,
              requestSent: requestSent,
              requestReceived: requestReceived,
              onAdd: () => requireAccountThen(context, store, () => store.sendFriendRequest(personId)),
              onCancel: () => store.cancelFriendRequest(personId),
              onAccept: () => store.acceptFriendRequest(personId),
              onDecline: () => store.declineFriendRequest(personId),
              onFriendsTap: () => _moreMenu(store, person),
              // Anyone can message anyone on FUNKY — being friends only
              // gates seeing each other's older memories.
              onMessage: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: personId))),
            ),
          const SizedBox(height: 12),
          Text(
            '${formatCount(person.points)} Funky points  ·  Level ${formatCount(levelFor(person.points))}',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          UnderlineTabs(labels: const ['Memories', 'Places'], index: _tab, onTap: (i) => setState(() => _tab = i)),
          const SizedBox(height: 12),
          if (_tab == 0) ...[
            if (memories.isEmpty)
              EmptyNote(text: isFriend || isSelf ? 'No memories yet.' : 'Nothing posted tonight.')
            else
              GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: memories.length,
                itemBuilder: (context, i) {
                  final s = memories[i];
                  return MemoryTile(
                    story: s,
                    placeName: memoryPlaceName(s, store),
                    onTap: () => openMemory(context, store, personId, s),
                  );
                },
              ),
            if (!isFriend && !isSelf && !banned)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FunkyCard(
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline, color: tokens.mute, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Add @${person.handle} as a friend to see all their memories.",
                          style: TextStyle(color: tokens.mute, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ] else ...[
            if (places.isEmpty)
              const EmptyNote(text: 'No tagged spots yet.')
            else
              PlacesGrid(places: places, personId: personId, scrollable: false),
          ],
          const SizedBox(height: 18),
          Center(
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                rootShellTabRequest.value = 3;
              },
              icon: Icon(Icons.location_on, color: tokens.brand),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Explore tagged spots in Places', style: TextStyle(color: tokens.mute, fontSize: 13.5)),
                  Icon(Icons.chevron_right_rounded, color: tokens.mute),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Add friend" (orange) + "Message", or the right state for where your
/// friendship stands.
class _FriendButtons extends StatelessWidget {
  final bool isFriend;
  final bool requestSent;
  final bool requestReceived;
  final VoidCallback onAdd;
  final VoidCallback onCancel;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onFriendsTap;
  final VoidCallback onMessage;

  const _FriendButtons({
    required this.isFriend,
    required this.requestSent,
    required this.requestReceived,
    required this.onAdd,
    required this.onCancel,
    required this.onAccept,
    required this.onDecline,
    required this.onFriendsTap,
    required this.onMessage,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(11));
    const pad = EdgeInsets.symmetric(vertical: 10);
    const label = TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5);

    Widget filled(IconData icon, String text, VoidCallback onTap) => ElevatedButton.icon(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, foregroundColor: Colors.white, elevation: 0, padding: pad, shape: shape),
          icon: Icon(icon, size: 19),
          label: Text(text, style: label),
        );
    Widget outlined(IconData icon, String text, VoidCallback onTap, {Color? color}) => OutlinedButton.icon(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: color ?? tokens.ink,
            backgroundColor: tokens.surface,
            padding: pad,
            side: BorderSide(color: tokens.line),
            shape: shape,
          ),
          icon: Icon(icon, size: 18),
          label: Text(text, style: label),
        );

    final Widget first;
    if (isFriend) {
      first = outlined(Icons.how_to_reg_rounded, 'Friends', onFriendsTap, color: tokens.friend);
    } else if (requestReceived) {
      first = filled(Icons.person_add_alt_1_rounded, 'Accept', onAccept);
    } else if (requestSent) {
      first = outlined(Icons.schedule_rounded, 'Requested', onCancel, color: tokens.mute);
    } else {
      first = filled(Icons.person_add_alt_1_rounded, 'Add friend', onAdd);
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: first),
            const SizedBox(width: 10),
            Expanded(child: outlined(Icons.chat_bubble_outline_rounded, 'Message', onMessage)),
          ],
        ),
        if (requestReceived)
          TextButton(
            onPressed: onDecline,
            child: Text('Decline request', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700)),
          ),
        if (requestSent)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Tap Requested to cancel it.', style: TextStyle(color: tokens.mute, fontSize: 12)),
          ),
      ],
    );
  }
}
