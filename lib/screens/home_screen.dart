import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../data/post_models.dart';
import '../data/session.dart' as session;
import '../widgets/kind_picker.dart';
import '../widgets/location_gate.dart';
import '../widgets/place_rating_card.dart';
import '../widgets/poll_bars.dart';
import '../widgets/poll_card.dart';
import '../widgets/rainbow_ring.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/org_badge.dart';
import '../data/when_labels.dart';
import 'upcoming_section.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'add_friends_screen.dart';
import 'create_sheet.dart';
import 'polls_screen.dart';
import 'posts_screen.dart';
import 'profile_parts.dart' show storyMedia;
import 'place_detail_screen.dart';
import '../root_shell.dart';
import 'story_viewer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // The big Tonight / Friends switch under the story rings, and the kind
  // of spot picked underneath it (All, Bars, Clubs, Parties…).
  _HomeSide _side = _HomeSide.tonight;
  _HomeKind _kind = _HomeKind.all;

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
    // Only Stories from the last 24 hours make a ring. On the Friends tab
    // the rings are your friends' stories from anywhere; everywhere else
    // they're stories posted inside your area (your radius).
    final friendsOnly = _side == _HomeSide.friends;
    bool isFriend(String uid) => store.me.friends.contains(uid);
    bool counts(Story s) => friendsOnly ? isFriend(s.uid) : store.isStoryNearby(s);
    bool hasUnseenFrom(String uid) => store.liveStoriesByUser(uid).any((s) => counts(s) && !s.views.contains('me'));
    final storytellerIds = <String>{
      for (final s in store.stories)
        if (store.isLiveStory(s) && counts(s) && (s.place == null || s.place == 'main' || store.isPlaceVerified(s.place!))) s.uid,
    }..remove('me')..removeWhere(store.isHidden);
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
    // Signed out: "Your story" is just the plain add ring — no leftover
    // picture or Stories from the account that signed out.
    final myStories = store.signedIn ? store.myLiveStories : const <Story>[];
    final hasMyStories = myStories.isNotEmpty;
    // Same order as the rings below — "Your story" first (when you have
    // one), then everyone else, unseen first — shared with the viewer so a
    // left/right swipe there moves through this exact same queue.
    final storyQueue = [if (hasMyStories) 'me', ...sortedStorytellerIds];
    // Tonight's chat, or the last 24 hours right after the 2 PM reset.
    final recentAreaMessages = store.liveChatReplay;

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
                  seed: store.signedIn ? store.me.id : 'guest',
                  photoPath: store.signedIn ? store.me.photoPath : null,
                  photoUrl: store.signedIn ? store.me.photoUrl : null,
                  // Once you've posted, the ring shows a little preview of
                  // your newest Story instead of your profile picture.
                  preview: hasMyStories ? storyMedia(myStories.first, tokens) : null,
                  onTap: hasMyStories
                      ? () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: storyQueue, initialIndex: 0, nearOnly: !friendsOnly)))
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
                      MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: storyQueue, initialIndex: storyQueue.indexOf(uid), nearOnly: !friendsOnly)),
                    ),
                  );
                }),
              ],
            ),
          ),
          // Not signed in and guest browsing couldn't start: say so instead of
          // showing an empty night.
          if (!store.signedIn && !store.isGuest && store.guestUnavailableReason != null)
            FunkyCard(
              margin: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Log in to see what's happening near you", style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    store.guestUnavailableReason == 'No connection.'
                        ? "We couldn't reach FUNKY — check your connection."
                        : 'Places, stories and live chat show up once you log in or make a free account.',
                    style: TextStyle(color: tokens.mute, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  FunkyChip(
                    label: 'Log in / Sign up',
                    active: true,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen(closeOnSuccess: true))),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          _SideSwitch(
            side: _side,
            onChanged: (s) => setState(() {
              _side = s;
              // Upcoming has no bars or clubs (they're there every night).
              if (s == _HomeSide.upcoming && !_HomeKind.upcomingKinds.contains(_kind)) _kind = _HomeKind.all;
            }),
          ),
          const SizedBox(height: 12),
          _KindBar(
            selected: _kind,
            kinds: _side == _HomeSide.upcoming ? _HomeKind.upcomingKinds : _HomeKind.values,
            onChanged: (k) => setState(() => _kind = k),
          ),
          if (_side == _HomeSide.friends)
            _FriendsTonight(kind: _kind)
          else if (_side == _HomeSide.upcoming)
            UpcomingSection(
              kinds: _kind.kinds,
              includeEventPosts: _kind == _HomeKind.all || _kind == _HomeKind.events,
              emptyLabel: _kind == _HomeKind.all ? 'parties or events' : _kind.plural,
            )
          else if (_kind != _HomeKind.all)
            _TonightKind(kind: _kind)
          else ...[
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
            // Jump to the Map tab (pushing a second copy of it on top used to
            // leave you stuck there with no back button or tab bar).
            onAction: () => rootShellTabRequest.value = 3,
          ),
          if (verifiedPlaces.isEmpty)
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.rankedPlaces.isEmpty
                        ? 'Nothing is listed within ${rangeLabel()} yet. Put the first spot on the map.'
                        : "Nothing verified near you yet — venues need 15 confirmations before they show up here. Check the Map tab to confirm one.",
                    style: TextStyle(color: tokens.ink),
                  ),
                  const SizedBox(height: 10),
                  FunkyChip(label: 'Add a place or event', active: true, onPressed: () => showCreateSheet(context, initial: CreateKind.place)),
                ],
              ),
            )
          else
            SizedBox(
              height: 156,
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
                              child: OrgBadgeCorner(
                                badge: placeOrgBadge(p.place),
                                small: true,
                                inset: 4,
                                child: PlaceMediaThumbnail(
                                  story: store.latestMediaStoryFor(p.id),
                                  coverPhotoPath: p.coverPhotoPath,
                                  coverUrl: p.coverUrl,
                                  photoUrl: p.photoUrl,
                                  fallbackLabel: p.name.substring(0, 1),
                                  fontSize: 22,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          RatingSummaryLine(placeId: p.id),
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
          // Tonight's events (event posts), soonest first.
          if (store.tonightEventPosts.isNotEmpty) ...[
            SectionHeader(
              title: 'Events tonight',
              action: 'Add event',
              onAction: () => showCreateSheet(context, initial: CreateKind.post),
            ),
            UpcomingEventsStrip(events: store.tonightEventPosts.take(10).toList()),
          ],
          // A peek at what's coming up, with a jump to the Upcoming side.
          if (store.upcomingPlaces.isNotEmpty || store.upcomingEventPosts.isNotEmpty) ...[
            SectionHeader(
              title: 'Coming up',
              action: 'See all',
              onAction: () => setState(() {
                _side = _HomeSide.upcoming;
                _kind = _HomeKind.all;
              }),
            ),
            for (final p in store.upcomingPlaces.take(2)) UpcomingPlaceCard(place: p),
            if (store.upcomingPlaces.isEmpty)
              UpcomingEventsStrip(events: store.upcomingEventPosts.take(10).toList()),
          ],
          // Posts: everyone's in your area, most liked first.
          SectionHeader(
            title: 'Posts',
            action: store.postsNearby.isEmpty ? 'New post' : 'See all',
            onAction: store.postsNearby.isEmpty
                ? () => showCreateSheet(context, initial: CreateKind.post)
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PostsFeedScreen())),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              "🏆 Tonight's top 3 posts near you win 500 · 300 · 150 Funky points",
              style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (store.postsNearby.isEmpty)
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No posts around here yet.', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Share a few pics from tonight, or ask something like "Anyone up for trivia?". Everyone in your area sees it.',
                    style: TextStyle(color: tokens.mute, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  FunkyChip(label: 'Make a post', active: true, onPressed: () => showCreateSheet(context, initial: CreateKind.post)),
                ],
              ),
            )
          else ...[
            PostsGrid(posts: store.rankPosts(store.postsNearby).take(6).toList()),
            if (store.postsNearby.length > 6)
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PostsFeedScreen())),
                  child: Text('See all ${store.postsNearby.length} posts', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
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
            const _LiveChatPreview(),
          SectionHeader(
            title: 'Polls',
            action: 'Ask a poll',
            onAction: () => showCreateSheet(context, initial: CreateKind.poll),
          ),
          // Top 3 (most votes) here; the rest are one tap away.
          if (store.visiblePolls.isEmpty)
            const EmptyNote(text: 'No other polls tonight. Ask the first one.')
          else ...[
            for (final poll in store.rankedVisiblePolls.take(3)) PollCard(key: ValueKey(poll.id), poll: poll),
            if (store.visiblePolls.length > 3)
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllPollsScreen())),
                  child: Text(
                    'View all ${store.visiblePolls.length} polls',
                    style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
          ],
          FootNote(text: 'Chat, Stories and polls reset at 2 PM (posts and FUNKY-verified places stay). Next fresh start in ${session.untilReset()}.'),
          ],
        ],
      ),
    );
  }
}

/// The big switch under the story rings: what's happening around you
/// tonight, or what your friends are up to.
enum _HomeSide { tonight, upcoming, friends }

/// The kinds of spot under the switch. "All" is the full page.
enum _HomeKind {
  all,
  bars,
  clubs,
  parties,
  events,
  tailgate,
  fraternity;

  /// What the Upcoming side offers — no bars or clubs.
  static const upcomingKinds = [all, parties, events, tailgate, fraternity];
}

extension on _HomeKind {
  String get label => switch (this) {
        _HomeKind.all => 'All',
        _HomeKind.bars => 'Bars',
        _HomeKind.clubs => 'Clubs',
        _HomeKind.parties => 'Parties',
        _HomeKind.events => 'Events',
        _HomeKind.tailgate => 'Tailgates',
        _HomeKind.fraternity => 'Frats',
      };

  IconData get icon => switch (this) {
        _HomeKind.all => Icons.apps_rounded,
        _HomeKind.bars => Icons.local_bar_outlined,
        _HomeKind.clubs => Icons.nightlife_rounded,
        _HomeKind.parties => Icons.celebration_outlined,
        _HomeKind.events => Icons.confirmation_number_outlined,
        _HomeKind.tailgate => Icons.sports_football_outlined,
        _HomeKind.fraternity => Icons.account_balance_outlined,
      };

  /// The kinds of place this filter covers.
  Set<PlaceKind> get kinds => switch (this) {
        _HomeKind.bars => const {PlaceKind.bar},
        _HomeKind.clubs => const {PlaceKind.club},
        _HomeKind.parties => const {PlaceKind.party},
        _HomeKind.events => const {PlaceKind.event},
        _HomeKind.tailgate => const {PlaceKind.tailgate},
        _HomeKind.fraternity => const {PlaceKind.frat},
        _HomeKind.all => const <PlaceKind>{},
      };

  /// "bars", "parties"… for headings and empty-state sentences.
  String get plural => switch (this) {
        _HomeKind.bars => 'bars',
        _HomeKind.clubs => 'clubs',
        _HomeKind.parties => 'parties',
        _HomeKind.events => 'events',
        _HomeKind.tailgate => 'tailgates',
        _HomeKind.fraternity => 'frat parties',
        _HomeKind.all => 'spots',
      };

  /// Whether [kind] (a post's or place's kind, or null) passes this filter.
  bool matches(PlaceKind? kind) => this == _HomeKind.all || (kind != null && kinds.contains(kind));
}

/// Three big squares side by side: Tonight, Upcoming and Friends.
class _SideSwitch extends StatelessWidget {
  final _HomeSide side;
  final ValueChanged<_HomeSide> onChanged;
  const _SideSwitch({required this.side, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final spots = store.verifiedRankedPlaces.length;
    final soon = store.upcomingPlaces.length + store.upcomingEventPosts.length;
    final friendsOut = store.signedIn ? store.myFriends.where((f) => f.move != null && f.move != 'in').length : 0;

    Widget tile(_HomeSide s, IconData icon, String title, String sub) {
      final active = s == side;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(s),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            height: 92,
            padding: const EdgeInsets.fromLTRB(11, 10, 8, 10),
            decoration: BoxDecoration(
              gradient: active ? LinearGradient(colors: [tokens.orange, tokens.brand], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
              color: active ? null : tokens.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: active ? Colors.transparent : tokens.line, width: 1.2),
              boxShadow: active ? [BoxShadow(color: tokens.orange.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 5))] : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: active ? Colors.white.withValues(alpha: 0.22) : tokens.raised),
                  child: Icon(icon, color: active ? Colors.white : tokens.ink, size: 18),
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: active ? Colors.white : tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: active ? Colors.white.withValues(alpha: 0.85) : tokens.mute, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tile(_HomeSide.tonight, Icons.nightlife_rounded, 'Tonight', spots == 1 ? '1 spot' : '$spots spots'),
        const SizedBox(width: 8),
        tile(_HomeSide.upcoming, Icons.event_rounded, 'Upcoming', soon == 0 ? 'Plan ahead' : '$soon coming up'),
        const SizedBox(width: 8),
        tile(_HomeSide.friends, Icons.groups_rounded, 'Friends', store.signedIn ? '$friendsOut going out' : 'Your crew'),
      ],
    );
  }
}

/// The spot kinds under the switch: All, Bars, Clubs, Parties…
class _KindBar extends StatelessWidget {
  final _HomeKind selected;
  final List<_HomeKind> kinds;
  final ValueChanged<_HomeKind> onChanged;
  const _KindBar({required this.selected, required this.kinds, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: kinds.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final k = kinds[i];
          return _KindChip(kind: k, active: k == selected, onTap: () => onChanged(k));
        },
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final _HomeKind kind;
  final bool active;
  final VoidCallback onTap;
  const _KindChip({required this.kind, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? tokens.ink : tokens.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: active ? tokens.ink : tokens.line, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kind.icon, size: 15, color: active ? tokens.bg : tokens.mute),
            const SizedBox(width: 5),
            Text(kind.label, style: TextStyle(color: active ? tokens.bg : tokens.ink, fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// Tonight + a spot kind: those spots near you, then posts tagged at them.
class _TonightKind extends StatelessWidget {
  final _HomeKind kind;
  const _TonightKind({required this.kind});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final isEvents = kind == _HomeKind.events;
    final posts = store.rankPosts(store.postsNearby.where((p) => (isEvents && p.isEvent) || kind.matches(store.postPlaceKind(p))));
    final events = isEvents ? store.tonightEventPosts : const <Post>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isEvents) ...[
          SectionHeader(
            title: 'Events tonight',
            action: 'Add event',
            onAction: () => showCreateSheet(context, initial: CreateKind.post),
          ),
          if (events.isEmpty)
            const EmptyNote(text: 'No event posts for tonight near you. Check Upcoming for what\'s coming, or post one: flip on "This is an event" when you make a post.')
          else
            UpcomingEventsStrip(events: events.take(15).toList()),
        ],
        _PlacesOfKind(kind: kind),
        if (posts.isNotEmpty) ...[
          SectionHeader(
            title: 'Posts at ${kind.plural}',
            action: posts.length > 6 ? 'See all' : null,
            onAction: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PostsFeedScreen(kinds: kind.kinds, title: '${kind.label} posts'),
            )),
          ),
          PostsGrid(posts: posts.take(6).toList()),
          if (posts.length > 6)
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PostsFeedScreen(kinds: kind.kinds, title: '${kind.label} posts'),
                )),
                child: Text('See all ${posts.length} posts', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ],
    );
  }
}

/// The Friends side: your friends' stories are in the rings up top; this
/// shows where they're going tonight and everything they've posted
/// (from anywhere, not just your area), narrowed by the spot kind.
class _FriendsTonight extends StatelessWidget {
  final _HomeKind kind;
  const _FriendsTonight({required this.kind});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (!store.signedIn) {
      return _TabNote(
        text: 'Make an account to add friends and see where they are headed tonight.',
        action: 'Create a free account',
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen(closeOnSuccess: true))),
      );
    }
    final friends = store.myFriends.where((f) => !store.isHidden(f.id)).toList();
    if (friends.isEmpty) {
      return _TabNote(
        text: 'No friends on FUNKY yet. Add some to see where everyone is going tonight.',
        action: 'Find friends',
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddFriendsScreen())),
      );
    }

    final byPlace = <String, List<Person>>{};
    final stayingIn = <Person>[];
    final undecided = <Person>[];
    for (final f in friends) {
      final move = f.move;
      if (move == null) {
        undecided.add(f);
      } else if (move == 'in') {
        stayingIn.add(f);
      } else {
        (byPlace[move] ??= []).add(f);
      }
    }
    Place? placeFor(String id) {
      for (final p in store.places) {
        if (p.id == id) return p;
      }
      return null;
    }
    final placeIds = byPlace.keys.where((id) => kind.matches(placeFor(id)?.kind)).toList()
      ..sort((a, b) => byPlace[b]!.length.compareTo(byPlace[a]!.length));
    final friendPosts = store.rankPosts(store.friendsPosts.where((p) => kind.matches(store.postPlaceKind(p))));
    void openFriendPosts() => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PostsFeedScreen(friends: true, kinds: kind == _HomeKind.all ? null : kind.kinds),
        ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: kind == _HomeKind.all ? 'Where your friends are going' : 'Friends going to ${kind.plural}'),
        if (placeIds.isEmpty)
          EmptyNote(
            text: kind == _HomeKind.all ? "None of your friends has picked a spot yet tonight." : 'None of your friends are headed to ${kind.plural} yet.',
          )
        else
          ...placeIds.map((id) {
            final place = placeFor(id);
            final going = byPlace[id]!;
            return GestureDetector(
              onTap: place == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: id))),
              behavior: HitTestBehavior.opaque,
              child: FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: PlaceMediaThumbnail(
                          story: store.latestMediaStoryFor(id),
                          coverPhotoPath: place?.coverPhotoPath,
                          coverUrl: place?.coverUrl,
                          photoUrl: place?.photoUrl,
                          fallbackLabel: (place?.name.isNotEmpty ?? false) ? place!.name.substring(0, 1) : '?',
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(place?.name ?? 'Somewhere nearby',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 6),
                          _AvatarRow(people: going),
                        ],
                      ),
                    ),
                    Text('${going.length}', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 18)),
                  ],
                ),
              ),
            );
          }),
        SectionHeader(
          title: "Friends' posts",
          action: friendPosts.length > 6 ? 'See all' : null,
          onAction: openFriendPosts,
        ),
        if (friendPosts.isEmpty)
          EmptyNote(text: kind == _HomeKind.all ? 'None of your friends have posted yet.' : 'No posts from friends at ${kind.plural} yet.')
        else ...[
          PostsGrid(posts: friendPosts.take(6).toList()),
          if (friendPosts.length > 6)
            Center(
              child: TextButton(
                onPressed: openFriendPosts,
                child: Text('See all ${friendPosts.length} posts', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
        // Upcoming parties/events your friends said they're going to.
        Builder(builder: (context) {
          final soon = store.upcomingPlaces
              .where((p) => (kind == _HomeKind.all || kind.kinds.contains(p.kind)) && store.friendsGoingToPlace(p.id).isNotEmpty)
              .toList();
          if (soon.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'Friends going soon'),
              for (final p in soon.take(5)) UpcomingPlaceCard(place: p),
            ],
          );
        }),
        if (kind == _HomeKind.all && stayingIn.isNotEmpty) ...[
          const SectionHeader(title: 'Staying in'),
          FunkyCard(child: _AvatarRow(people: stayingIn)),
        ],
        if (kind == _HomeKind.all && undecided.isNotEmpty) ...[
          const SectionHeader(title: "Haven't picked yet"),
          FunkyCard(child: _AvatarRow(people: undecided)),
        ],
      ],
    );
  }
}

/// A few overlapping friend avatars plus their names.
class _AvatarRow extends StatelessWidget {
  final List<Person> people;
  const _AvatarRow({required this.people});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final shown = people.take(5).toList();
    final names = people.take(3).map((p) => '@${p.handle}').join(', ');
    final extra = people.length - 3;
    return Row(
      children: [
        SizedBox(
          width: 22.0 * shown.length + 8,
          height: 30,
          child: Stack(
            children: [
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: 22.0 * i,
                  child: Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.surface, width: 2)),
                    child: PersonAvatar(person: shown[i], size: 26),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            extra > 0 ? '$names and $extra more' : names,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

/// Home's Bars / Parties / Events / Tailgate / Fraternity tabs: every spot of
/// that kind within your range, busiest first.
class _PlacesOfKind extends StatelessWidget {
  final _HomeKind kind;
  const _PlacesOfKind({required this.kind});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final kinds = kind.kinds;
    final list = store.rankedPlaces.where((p) => kinds.contains(p.kind) && !store.isBanned(p.place.by)).toList();
    final friendIds = store.me.friends.toSet();
    if (list.isEmpty) {
      return _TabNote(
        text: 'No ${kind.plural} listed within ${rangeLabel()} yet. Put the first one on the map.',
        action: 'Add a place or event',
        onAction: () => showCreateSheet(context, initial: CreateKind.place),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: '${kind.label} near you'),
        ...list.map((p) {
          final verified = store.isPlaceVerified(p.id);
          final friendsGoing = friendIds.where((id) => store.people[id]?.move == p.id).length;
          return GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
            behavior: HitTestBehavior.opaque,
            child: FunkyCard(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: OrgBadgeCorner(
                        badge: placeOrgBadge(p.place),
                        small: true,
                        inset: 3,
                        child: PlaceMediaThumbnail(
                          story: store.latestMediaStoryFor(p.id),
                          coverPhotoPath: p.coverPhotoPath,
                          coverUrl: p.coverUrl,
                          photoUrl: p.photoUrl,
                          fallbackLabel: p.name.isNotEmpty ? p.name.substring(0, 1) : '?',
                          fontSize: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(p.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                            ),
                            if (verified) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.verified, size: 15, color: store.isAdminVerified(p.id) ? tokens.gold : tokens.brand),
                            ],
                            if (store.hasBeenTo(p.id)) ...[
                              const SizedBox(width: 4),
                              BeenHereBadge(size: 16, nights: store.nightsAt(p.id)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            p.place.eventType != null ? placeEventTypeLabel(p.place.eventType) : placeKindLabel(p.kind),
                            if (p.place.startsAt != null) clockLabel(p.place.startsAt!),
                            p.distance < 0.1 ? 'right by you' : '${formatMiles(p.distance)} away',
                          ].join(' · '),
                          style: TextStyle(color: tokens.mute, fontSize: 12),
                        ),
                        // A bar's event tonight ("🧠 Trivia Night tonight").
                        Builder(builder: (context) {
                          final ev = store.tonightEventAt(p.id);
                          if (ev == null) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '${placeEventTypeEmoji(ev.eventType)} ${ev.name} tonight${ev.startsAt != null ? ' · ${clockLabel(ev.startsAt!)}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 12),
                            ),
                          );
                        }),
                        const SizedBox(height: 2),
                        RatingSummaryLine(placeId: p.id),
                        if (p.going > 0 || friendsGoing > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (p.going > 0) '🔥 ${p.going} going',
                              if (friendsGoing > 0) '$friendsGoing friend${friendsGoing == 1 ? '' : 's'}',
                            ].join(' · '),
                            style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: tokens.mute),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

/// An empty-state card with one button, used by the Home tabs.
class _TabNote extends StatelessWidget {
  final String text;
  final String action;
  final VoidCallback onAction;
  const _TabNote({required this.text, required this.action, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return FunkyCard(
      margin: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(color: tokens.ink)),
          const SizedBox(height: 10),
          FunkyChip(label: action, active: true, onPressed: onAction),
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
  // Shown inside the ring instead of the avatar (your newest Story).
  final Widget? preview;
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
    this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final showBadge = isAdd || onAddBadgeTap != null;
    final Color ringColor = tokens.line;
    final Widget inner = preview != null
        ? ClipOval(child: SizedBox(width: 56, height: 56, child: preview))
        : FunkyAvatar(seed: seed, label: label, size: 56, photoPath: photoPath, photoUrl: photoUrl);
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
                // A Story you haven't watched yet: spinning rainbow ring.
                // Already watched (or your own): plain gray.
                if (!isAdd && unseen)
                  RainbowRing(
                    size: 64,
                    strokeWidth: 3,
                    child: inner,
                  )
                else
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: ringColor, width: 2.5),
                    ),
                    child: inner,
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




/// The three-line Live Chat peek on Home. While people are actually talking
/// (a message in the last 15 minutes) it just shows the latest three. When
/// the room has gone quiet it behaves like a live feed replaying older
/// messages (tonight's, plus the last 24 hours so it still moves right after
/// the 2 PM reset): every few seconds the top line slips away and the next
/// one slides in at the bottom, one at a time, looping forever.
class _LiveChatPreview extends StatefulWidget {
  const _LiveChatPreview();

  @override
  State<_LiveChatPreview> createState() => _LiveChatPreviewState();
}

class _LiveChatPreviewState extends State<_LiveChatPreview> {
  static const _activeWindowMs = 15 * 60 * 1000;
  Timer? _timer;
  // Non-null only while the replay loop is running.
  List<ChatMessage>? _items;
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  int _cursor = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Someone said something in Live Chat in the last 15 minutes.
  bool _isActive(List<ChatMessage> tonight) {
    if (tonight.isEmpty) return false;
    return DateTime.now().millisecondsSinceEpoch - tonight.last.t <= _activeWindowMs;
  }

  /// How many lines show at once while looping — three, or fewer when
  /// there are only a couple of messages to cycle through.
  static int _window(int n) => n > 3 ? 3 : n - 1;

  void _tick() {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final msgs = store.liveChatReplay;
    if (msgs.length < 2 || _isActive(store.liveChatMessages)) {
      if (_items != null) setState(() => _items = null);
      return;
    }
    final items = _items;
    if (items == null) {
      // Start from the latest few; the next one in is the very first
      // message, so it reads as one continuous feed.
      setState(() {
        _items = msgs.sublist(msgs.length - _window(msgs.length));
        _listKey = GlobalKey<AnimatedListState>();
        _cursor = 0;
      });
      return;
    }
    final list = _listKey.currentState;
    if (list == null) return;
    if (_cursor >= msgs.length) _cursor = 0;
    final next = msgs[_cursor];
    _cursor = (_cursor + 1) % msgs.length;
    final gone = items.removeAt(0);
    list.removeItem(
      0,
      (ctx, anim) => _row(ctx, store, gone, anim, leaving: true),
      duration: const Duration(milliseconds: 380),
    );
    items.add(next);
    list.insertItem(items.length - 1, duration: const Duration(milliseconds: 650));
  }

  Widget _row(BuildContext context, AppStore store, ChatMessage m, Animation<double> anim, {bool leaving = false}) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final handle = m.uid == 'me' ? store.myChatHandle : (store.people[m.uid]?.handle ?? m.uid);
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          m.anon
              ? Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12))
              : FunkyHandle(handle: handle, person: m.uid == 'me' ? (store.signedIn ? store.me : null) : store.people[m.uid]),
          if (m.uid != 'me' && m.lat != null && m.lng != null && store.location != null)
            Text(
              awayLabel(milesBetween(store.location!, LatLng(m.lat!, m.lng!))),
              style: TextStyle(color: tokens.mute, fontSize: 10.5),
            ),
          filteredMessageText(
            m.text.trim().isNotEmpty
                ? m.text
                : (m.gifUrl != null ? 'sent a GIF' : (m.sharedPlaceId != null ? '📍 shared a spot' : (m.pollId != null ? '📊 shared a poll' : ''))),
            TextStyle(color: tokens.ink),
            myHandle: store.me.handle,
            mentions: true,
          ),
        ],
      ),
    );
    if (leaving) {
      // Top line slides off to the left while the card closes the gap.
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeIn);
      return SizeTransition(
        sizeFactor: curved,
        axisAlignment: -1,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(-1.0, 0), end: Offset.zero).animate(curved),
          child: content,
        ),
      );
    }
    // New line: the card opens a gap, then the message slides in from the
    // right — no fading, just motion.
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: anim, curve: const Interval(0.0, 0.5, curve: Curves.easeOut)),
      axisAlignment: -1,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(1.0, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final tonight = store.liveChatMessages;
    final pool = store.liveChatReplay;
    if (tonight.isEmpty && pool.isEmpty) return const EmptyNote(text: 'Quiet so far. Be the first to ask what the move is.');
    final msgs = tonight.isNotEmpty && _isActive(tonight) ? tonight : pool;

    final items = _items;
    if (items != null && pool.length >= 2 && !_isActive(tonight)) {
      return FunkyCard(
        child: ClipRect(
         child: AnimatedList(
          key: _listKey,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          initialItemCount: items.length,
          itemBuilder: (ctx, i, anim) {
            if (i >= items.length) return const SizedBox.shrink();
            return _row(ctx, store, items[i], anim);
          },
         ),
        ),
      );
    }

    final shown = msgs.length > 3 ? msgs.sublist(msgs.length - 3) : msgs;
    return FunkyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final m in shown) _row(context, store, m, const AlwaysStoppedAnimation<double>(1))],
      ),
    );
  }
}
