import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../data/session.dart' as session;
import '../widgets/kind_picker.dart';
import '../widgets/location_gate.dart';
import '../widgets/place_rating_card.dart';
import '../widgets/poll_bars.dart';
import '../widgets/rainbow_ring.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'add_friends_screen.dart';
import 'create_sheet.dart';
import 'places_screen.dart';
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
  // Which tab under the story rings is showing — Tonight is the full feed.
  _HomeTab _tab = _HomeTab.tonight;

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
    final friendsOnly = _tab == _HomeTab.friends;
    bool isFriend(String uid) => store.me.friends.contains(uid);
    bool counts(Story s) => friendsOnly ? isFriend(s.uid) : store.isStoryNearby(s);
    bool hasUnseenFrom(String uid) => store.liveStoriesByUser(uid).any((s) => counts(s) && !s.views.contains('me'));
    final storytellerIds = <String>{
      for (final s in store.stories)
        if (store.isLiveStory(s) && counts(s) && (s.place == null || s.place == 'main' || store.isPlaceVerified(s.place!))) s.uid,
    }..remove('me')..removeWhere(store.isBanned);
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
          _HomeTabBar(selected: _tab, onChanged: (t) => setState(() => _tab = t)),
          if (_tab == _HomeTab.friends)
            const _FriendsTonight()
          else if (_tab != _HomeTab.tonight)
            _PlacesOfKind(tab: _tab)
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
            onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlacesScreen())),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(poll.q, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                        if (poll.by == 'me' || store.isAdmin)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _confirmDeletePoll(context, store, poll),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10, bottom: 4),
                              child: Icon(Icons.delete_outline, size: 20, color: tokens.mute),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    PollBars(options: poll.options, counts: counts, selectedIndex: mine, onSelect: (i) => store.votePoll(poll.id, i)),
                  ],
                ),
              );
            }),
          FootNote(text: 'Chat, Stories, places and polls are wiped at 2 PM. Next fresh start in ${session.untilReset()}.'),
          ],
        ],
      ),
    );
  }
}

/// The tabs under the story rings. Tonight and Friends lead; the rest
/// narrow the night down to one kind of spot.
enum _HomeTab { tonight, friends, bars, parties, events, tailgate, fraternity }

extension on _HomeTab {
  String get label => switch (this) {
        _HomeTab.tonight => 'Tonight',
        _HomeTab.friends => 'Friends',
        _HomeTab.bars => 'Bars',
        _HomeTab.parties => 'Parties',
        _HomeTab.events => 'Events',
        _HomeTab.tailgate => 'Tailgate',
        _HomeTab.fraternity => 'Fraternity',
      };

  IconData get icon => switch (this) {
        _HomeTab.tonight => Icons.calendar_today_outlined,
        _HomeTab.friends => Icons.groups_rounded,
        _HomeTab.bars => Icons.local_bar_outlined,
        _HomeTab.parties => Icons.celebration_outlined,
        _HomeTab.events => Icons.confirmation_number_outlined,
        _HomeTab.tailgate => Icons.sports_football_outlined,
        _HomeTab.fraternity => Icons.account_balance_outlined,
      };

  /// The kinds of place each spot tab lists (bars include clubs).
  Set<PlaceKind> get kinds => switch (this) {
        _HomeTab.bars => const {PlaceKind.bar, PlaceKind.club},
        _HomeTab.parties => const {PlaceKind.party},
        _HomeTab.events => const {PlaceKind.event},
        _HomeTab.tailgate => const {PlaceKind.tailgate},
        _HomeTab.fraternity => const {PlaceKind.frat},
        _ => const <PlaceKind>{},
      };

  /// "bars", "parties"… for empty-state sentences.
  String get plural => switch (this) {
        _HomeTab.bars => 'bars',
        _HomeTab.parties => 'parties',
        _HomeTab.events => 'events',
        _HomeTab.tailgate => 'tailgates',
        _HomeTab.fraternity => 'frat parties',
        _ => 'spots',
      };
}

class _HomeTabBar extends StatelessWidget {
  final _HomeTab selected;
  final ValueChanged<_HomeTab> onChanged;
  const _HomeTabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _HomeTab.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final tab = _HomeTab.values[i];
          return _HomeTabChip(tab: tab, active: tab == selected, onTap: () => onChanged(tab));
        },
      ),
    );
  }
}

class _HomeTabChip extends StatelessWidget {
  final _HomeTab tab;
  final bool active;
  final VoidCallback onTap;
  const _HomeTabChip({required this.tab, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: active ? tokens.brand : tokens.surface,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: active ? tokens.brand : tokens.line, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: 16, color: active ? Colors.white : tokens.mute),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: TextStyle(color: active ? Colors.white : tokens.ink, fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home's Friends tab: where your friends said they're going tonight.
class _FriendsTonight extends StatelessWidget {
  const _FriendsTonight();

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
    final friends = store.myFriends.where((f) => !store.isBanned(f.id)).toList();
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
    final placeIds = byPlace.keys.toList()..sort((a, b) => byPlace[b]!.length.compareTo(byPlace[a]!.length));
    Place? placeFor(String id) {
      for (final p in store.places) {
        if (p.id == id) return p;
      }
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Where your friends are going'),
        if (placeIds.isEmpty)
          const EmptyNote(text: "None of your friends has picked a spot yet tonight.")
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
        if (stayingIn.isNotEmpty) ...[
          const SectionHeader(title: 'Staying in'),
          FunkyCard(child: _AvatarRow(people: stayingIn)),
        ],
        if (undecided.isNotEmpty) ...[
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
  final _HomeTab tab;
  const _PlacesOfKind({required this.tab});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final kinds = tab.kinds;
    final list = store.rankedPlaces.where((p) => kinds.contains(p.kind) && !store.isBanned(p.place.by)).toList();
    final friendIds = store.me.friends.toSet();
    if (list.isEmpty) {
      return _TabNote(
        text: 'No ${tab.plural} listed within ${rangeLabel()} yet. Put the first one on the map.',
        action: 'Add a place or event',
        onAction: () => showCreateSheet(context, initial: CreateKind.place),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: '${tab.label} near you'),
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
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${placeKindLabel(p.kind)} · ${p.distance < 0.1 ? 'right by you' : '${formatMiles(p.distance)} away'}',
                          style: TextStyle(color: tokens.mute, fontSize: 12),
                        ),
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


Future<void> _confirmDeletePoll(BuildContext context, AppStore store, Poll poll) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this poll?'),
      content: Text('This removes "${poll.q}" and everyone\'s votes on it.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ),
  );
  if (ok == true) store.deletePoll(poll.id);
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
          filteredMessageText(m.text, TextStyle(color: tokens.ink), myHandle: store.me.handle, mentions: true),
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
