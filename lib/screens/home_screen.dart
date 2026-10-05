import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/session.dart' as session;
import '../widgets/kind_picker.dart';
import '../widgets/location_gate.dart';
import '../widgets/poll_bars.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'create_sheet.dart';
import 'places_screen.dart';
import 'place_detail_screen.dart';
import '../root_shell.dart';
import 'story_viewer_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (store.location == null) return const LocationGate();

    // "What's the move tonight?" builds itself from the busiest VERIFIED
    // places near you, plus "Staying in" — it is not a stored poll
    // (HANDOFF.md). An unconfirmed venue shouldn't be able to show up as a
    // vote option on Home before anyone's actually vouched it's real.
    final verifiedPlaces = store.verifiedRankedPlaces;
    final moveOptions = verifiedPlaces.take(4).toList();
    final moveLabels = [...moveOptions.map((p) => p.name), 'Staying in'];
    final allPeople = {...store.people, 'me': store.me};
    final stayingInCount = allPeople.values.where((p) => p.move == 'in').length;
    final moveCounts = [...moveOptions.map((p) => p.going), stayingInCount];
    int? moveSelectedIndex;
    if (store.me.move != null) {
      moveSelectedIndex = store.me.move == 'in' ? moveOptions.length : moveOptions.indexWhere((p) => p.id == store.me.move);
      if (moveSelectedIndex == -1) moveSelectedIndex = null;
    }

    final covered = verifiedPlaces.where((p) => p.reports[ReportKind.cover] != null).toList();
    // Who's actually posted a Story tonight at a VERIFIED venue (or a
    // general, not-venue-specific Story) — not "who's standing at a place
    // that happens to have stories" (that mismatch was why rings used to
    // show up for the wrong people and did nothing when tapped), and not
    // someone whose only Story tonight is at an unconfirmed venue.
    bool hasUnseenFrom(String uid) => store.storiesByUser(uid).any((s) => !s.views.contains('me'));
    final storytellerIds = <String>{
      for (final s in store.stories)
        if (s.place == null || s.place == 'main' || store.isPlaceVerified(s.place!)) s.uid,
    }..remove('me')..removeWhere(store.isBanned);
    bool isFriend(String uid) => store.me.friends.contains(uid);
    // Friends always lead the queue (green ring), full stop — ahead of
    // unwatched strangers, not just tie-broken by them. Within each of
    // those two groups, unwatched rings still come before already-watched
    // ones (same idea Snapchat/Instagram use), so a friend you haven't
    // seen yet still sits ahead of a friend you have.
    final sortedStorytellerIds = storytellerIds.toList()
      ..sort((a, b) {
        final aFriend = isFriend(a) ? 0 : 1;
        final bFriend = isFriend(b) ? 0 : 1;
        if (aFriend != bFriend) return aFriend.compareTo(bFriend);
        final aSeen = hasUnseenFrom(a) ? 0 : 1;
        final bSeen = hasUnseenFrom(b) ? 0 : 1;
        return aSeen.compareTo(bSeen);
      });
    final myStories = store.myStories;
    final hasMyStories = myStories.isNotEmpty;
    // Same order as the rings below — "Your story" first (when you have
    // one), then everyone else, unseen first — shared with the viewer so a
    // left/right swipe there moves through this exact same queue.
    final storyQueue = [if (hasMyStories) 'me', ...sortedStorytellerIds];
    final areaMessages = store.liveChatMessages;
    final recentAreaMessages = areaMessages.length > 3 ? areaMessages.sublist(areaMessages.length - 3) : areaMessages;

    return Container(
      color: tokens.bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          SizedBox(
            height: 84,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _StoryRing(
                  label: 'Your story',
                  // Only treated as a bare "add" ring (dashed/gray, camera
                  // badge is the whole thing) when you have nothing to show
                  // yet. Once you've posted, the ring itself opens your own
                  // Stories — tapping it used to always jump straight to
                  // the camera, with no way to just look back at what you
                  // already posted tonight.
                  isAdd: !hasMyStories,
                  // Never orange for your own ring — "unseen" doesn't mean
                  // anything for your own Stories, so this just always
                  // reads as the neutral/gray border.
                  unseen: false,
                  seed: store.me.id,
                  photoPath: store.me.photoPath,
                  photoUrl: store.me.photoUrl,
                  onTap: hasMyStories
                      ? () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: storyQueue, initialIndex: 0)))
                      : () => showCreateSheet(context),
                  // The little camera badge in the corner is always a
                  // shortcut straight to the camera, even once you have
                  // stories to look back at.
                  onAddBadgeTap: hasMyStories ? () => showCreateSheet(context) : null,
                ),
                ...sortedStorytellerIds.map((uid) {
                  final person = store.personById(uid);
                  if (person == null) return const SizedBox.shrink();
                  return _StoryRing(
                    label: person.handle,
                    seed: person.id,
                    photoPath: person.photoPath,
                    photoUrl: person.photoUrl,
                    unseen: hasUnseenFrom(uid),
                    isFriend: isFriend(uid),
                    onLongPress: () => openProfile(context, uid),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: storyQueue, initialIndex: storyQueue.indexOf(uid))),
                    ),
                  );
                }),
              ],
            ),
          ),
          FunkyCard(
            margin: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("WHAT'S THE MOVE TONIGHT?", style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.4)),
                const SizedBox(height: 10),
                PollBars(
                  options: moveLabels,
                  counts: moveCounts,
                  selectedIndex: moveSelectedIndex,
                  onSelect: (i) => store.setMove(i == moveOptions.length ? 'in' : moveOptions[i].id),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    '${moveCounts.fold<int>(0, (a, b) => a + b)} votes, ${session.untilReset()} left',
                    style: TextStyle(color: tokens.mute, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          SectionHeader(
            title: 'Trending nearby',
            action: 'See all',
            onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlacesScreen())),
          ),
          if (verifiedPlaces.isEmpty)
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.rankedPlaces.isEmpty
                        ? 'Nothing is listed within 25 miles yet. Put the first spot on the map.'
                        : "Nothing verified near you yet — venues need 15 confirmations before they show up here. Check the Places tab to confirm one.",
                    style: TextStyle(color: tokens.ink),
                  ),
                  const SizedBox(height: 10),
                  FunkyChip(label: 'Add a place or event', active: true, onPressed: () => showCreateSheet(context, initial: CreateKind.place)),
                ],
              ),
            )
          else
            SizedBox(
              height: 138,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: verifiedPlaces.take(8).map((p) {
                  return GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
                    child: Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: tokens.surface,
                        border: Border.all(color: tokens.line),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              height: 60,
                              width: double.infinity,
                              // Same switch as the Place Detail banner —
                              // shows the latest posted photo/video here
                              // once there is one.
                              child: PlaceMediaThumbnail(
                                story: store.latestMediaStoryFor(p.id),
                                coverPhotoPath: p.coverPhotoPath,
                                coverUrl: p.coverUrl,
                                fallbackLabel: p.name.substring(0, 1),
                                fontSize: 22,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text('🔥 ${p.going} going', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          if (covered.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text('Covers tonight', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            SizedBox(
              height: 70,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: covered.map((p) {
                  return GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
                    child: Container(
                      margin: const EdgeInsets.only(right: 10),
                      constraints: const BoxConstraints(minWidth: 110),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tokens.surface,
                        border: Border.all(color: tokens.line),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            p.reports[ReportKind.cover]?.detail ?? '?',
                            style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 18),
                          ),
                          Text(p.name, style: TextStyle(color: tokens.ink, fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
          SectionHeader(
            title: 'Live Chat',
            action: 'Open chat',
            // Switches RootShell to its own Chat tab instead of pushing a
            // standalone ChatScreen on top — see rootShellTabRequest's doc
            // comment in root_shell.dart for why.
            onAction: () => rootShellTabRequest.value = 1,
          ),
          if (recentAreaMessages.isEmpty)
            const EmptyNote(text: 'Quiet so far. Be the first to ask what the move is.')
          else
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: recentAreaMessages.map((m) {
                  final handle = m.uid == 'me' ? store.me.handle : (store.people[m.uid]?.handle ?? m.uid);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        m.anon
                            ? Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12))
                            : FunkyHandle(handle: handle, person: m.uid == 'me' ? store.me : store.people[m.uid]),
                        filteredMessageText(m.text, TextStyle(color: tokens.ink)),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          SectionHeader(
            title: 'Polls',
            action: 'Ask a poll',
            onAction: () => showCreateSheet(context, initial: CreateKind.poll),
          ),
          if (store.visiblePolls.isEmpty)
            const EmptyNote(text: 'No other polls tonight. Ask the first one.')
          else
            ...store.visiblePolls.map((poll) {
              final counts = store.pollCounts(poll);
              final mine = store.me.votes[poll.id];
              return FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(poll.q, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    PollBars(options: poll.options, counts: counts, selectedIndex: mine, onSelect: (i) => store.votePoll(poll.id, i)),
                  ],
                ),
              );
            }),
          FootNote(text: 'Chat, Stories, places and polls are wiped at 2 PM. Next fresh start in ${session.untilReset()}.'),
        ],
      ),
    );
  }
}

class _StoryRing extends StatelessWidget {
  final String label;
  final bool isAdd;
  // Whether this person has at least one Story you haven't watched yet —
  // drives the ring color (gray = already seen, so there's no reason to
  // still flag it at full brightness) for both friends and strangers alike
  // now — see isFriend below. Irrelevant for the bare "add" ring.
  final bool unseen;
  // Whether you and this person are friends — while unseen, draws the ring
  // green instead of the normal orange so a friend's Story still stands out
  // from a stranger's; once you've actually watched it (unseen flips to
  // false) a friend's ring drops to the same neutral gray a stranger's seen
  // ring uses, rather than staying green forever just for being a friend.
  // Separately (see sortedStorytellerIds) friends always sort to the front
  // regardless of seen state. Irrelevant for the bare "add" ring.
  final bool isFriend;
  final String seed;
  final String? photoPath;
  final String? photoUrl;
  final VoidCallback? onTap;
  // Press-and-hold on someone's ring jumps to their profile (a plain tap
  // opens their Stories).
  final VoidCallback? onLongPress;
  // When set, the little corner camera badge gets its OWN tap target
  // (always opens the camera) separate from [onTap] on the ring itself —
  // used for "Your story" once you have stories to look back at, so the
  // ring can open your Stories while the badge still jumps to the camera.
  final VoidCallback? onAddBadgeTap;
  const _StoryRing({
    required this.label,
    this.isAdd = false,
    this.unseen = true,
    this.isFriend = false,
    required this.seed,
    this.photoPath,
    this.photoUrl,
    this.onTap,
    this.onLongPress,
    this.onAddBadgeTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final showBadge = isAdd || onAddBadgeTap != null;
    final Color ringColor = isAdd ? tokens.line : (unseen ? (isFriend ? tokens.friend : tokens.orange) : tokens.line);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 72,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ringColor, width: 2.5),
                  ),
                  child: FunkyAvatar(seed: seed, label: label, size: 56, photoPath: photoPath, photoUrl: photoUrl),
                ),
                if (showBadge)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: GestureDetector(
                      onTap: onAddBadgeTap ?? onTap,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tokens.brand,
                          shape: BoxShape.circle,
                          border: Border.all(color: tokens.bg, width: 2.5),
                        ),
                        child: const Icon(Icons.camera_alt, color: Colors.white, size: 13),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
