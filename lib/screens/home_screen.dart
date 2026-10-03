import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/session.dart' as session;
import '../widgets/kind_picker.dart';
import '../widgets/location_gate.dart';
import '../widgets/poll_bars.dart';
import '../widgets/ui_widgets.dart';
import 'create_sheet.dart';
import 'places_screen.dart';
import 'place_detail_screen.dart';
import 'chat_screen.dart';
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
    final storytellerIds = <String>{
      for (final s in store.stories)
        if (s.place == null || s.place == 'main' || store.isPlaceVerified(s.place!)) s.uid,
    }..remove('me');
    final areaMessages = store.messagesFor('main');
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
                  isAdd: true,
                  seed: store.me.id,
                  onTap: () => showCreateSheet(context),
                ),
                ...storytellerIds.map((uid) {
                  final person = store.personById(uid);
                  if (person == null) return const SizedBox.shrink();
                  return _StoryRing(
                    label: person.handle,
                    seed: person.id,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(personId: uid))),
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
                          Container(
                            height: 60,
                            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
                            alignment: Alignment.center,
                            child: Text(p.name.substring(0, 1), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: tokens.mute)),
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
            onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChatScreen())),
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
                        m.anon ? Text('anonymous', style: TextStyle(color: tokens.mute, fontSize: 12)) : FunkyHandle(handle: handle),
                        Text(m.text, style: TextStyle(color: tokens.ink)),
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
  final String seed;
  final VoidCallback? onTap;
  const _StoryRing({required this.label, this.isAdd = false, required this.seed, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onTap,
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
                    border: Border.all(color: isAdd ? tokens.line : tokens.orange, width: 2.5),
                  ),
                  child: FunkyAvatar(seed: seed, label: label, size: 56),
                ),
                if (isAdd)
                  Positioned(
                    right: -2,
                    bottom: -2,
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
