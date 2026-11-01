import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/post_models.dart';
import '../data/session.dart';
import '../data/geo.dart';
import '../data/when_labels.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/kind_picker.dart';
import '../widgets/org_badge.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'create_sheet.dart';
import 'place_detail_screen.dart';
import 'posts_screen.dart';

/// Home's Upcoming side: parties, events, tailgates and frat parties dated
/// for a night after tonight, grouped by night, soonest first. On its night
/// each one moves over to Tonight by itself.
class UpcomingSection extends StatelessWidget {
  /// Which kinds to show (empty = all of them).
  final Set<PlaceKind> kinds;
  /// Also list event posts ("This is an event" posts).
  final bool includeEventPosts;
  final String emptyLabel;
  const UpcomingSection({super.key, this.kinds = const {}, this.includeEventPosts = true, this.emptyLabel = 'parties or events'});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final places = store.upcomingPlaces.where((p) => kinds.isEmpty || kinds.contains(p.kind)).toList();
    final posts = includeEventPosts ? store.upcomingEventPosts : const <Post>[];

    // One list of (night, time, card), soonest first.
    final items = <(String, DateTime, Widget)>[
      for (final p in places) (p.place.night!, p.place.startsAt!, UpcomingPlaceCard(place: p)),
      for (final post in posts) (sessionKey(post.eventAt!), post.eventAt!, _UpcomingPostCard(post: post)),
    ]..sort((a, b) => a.$2.compareTo(b.$2));

    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: FunkyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Nothing coming up yet', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                "No $emptyLabel dated within ${rangeLabel()} yet. Add one with a date and it shows here, then moves to Tonight on the night.",
                style: TextStyle(color: tokens.mute, fontSize: 13.5, height: 1.35),
              ),
              const SizedBox(height: 12),
              FunkyChip(
                label: 'Add a party or event',
                active: true,
                onPressed: () => requireGuestOkThen(context, store, () => showCreateSheet(context, initial: CreateKind.place)),
              ),
            ],
          ),
        ),
      );
    }

    final children = <Widget>[];
    String? lastNight;
    for (final item in items) {
      if (item.$1 != lastNight) {
        lastNight = item.$1;
        children.add(Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Row(
            children: [
              Text(nightHeading(item.$1), style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Expanded(child: Container(height: 1, color: tokens.line)),
            ],
          ),
        ));
      }
      children.add(item.$3);
    }
    children.add(Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Center(
        child: TextButton.icon(
          onPressed: () => requireGuestOkThen(context, store, () => showCreateSheet(context, initial: CreateKind.place)),
          icon: Icon(Icons.add_rounded, color: tokens.orange),
          label: Text('Add a party or event', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
        ),
      ),
    ));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// One upcoming party/event: its flyer (with the frat/school letters), name,
/// when, where, who's going, and an "I'm going" button.
class UpcomingPlaceCard extends StatelessWidget {
  final RankedPlace place;
  const UpcomingPlaceCard({super.key, required this.place});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final p = place.place;
    final going = store.hasRsvped(p.id);
    final friends = store.friendsGoingToPlace(p.id);
    final badge = placeOrgBadge(p);
    String? hostName;
    if (p.hostPlaceId != null) {
      for (final h in store.places) {
        if (h.id == p.hostPlaceId) hostName = h.name;
      }
    }
    final what = p.eventType != null ? '${placeEventTypeEmoji(p.eventType)} ${placeEventTypeLabel(p.eventType)}' : placeKindLabel(p.kind);
    final where = hostName != null ? 'at $hostName' : (place.distance < 0.1 ? 'right by you' : formatMiles(place.distance));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
      child: FunkyCard(
        margin: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 78,
                height: 96,
                child: OrgBadgeCorner(
                  badge: badge,
                  small: true,
                  inset: 4,
                  child: PlaceMediaThumbnail(
                    story: null,
                    coverPhotoPath: p.coverPhotoPath,
                    coverUrl: p.coverUrl,
                    photoUrl: p.photoUrl,
                    fallbackLabel: p.name.isNotEmpty ? p.name.substring(0, 1) : '?',
                    fontSize: 26,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                  const SizedBox(height: 3),
                  Text(
                    '${dayLabel(p.startsAt!)} · ${clockLabel(p.startsAt!)}',
                    style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                  const SizedBox(height: 2),
                  Text('$what · $where', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (friends.isNotEmpty) ...[
                        SizedBox(
                          width: 16.0 * friends.take(3).length + 8,
                          height: 22,
                          child: Stack(
                            children: [
                              for (var i = 0; i < friends.take(3).length; i++)
                                Positioned(
                                  left: 16.0 * i,
                                  child: Container(
                                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.surface, width: 1.5)),
                                    child: PersonAvatar(person: friends[i], size: 20, preview: false),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          place.going == 0
                              ? 'Be the first going'
                              : (friends.isNotEmpty ? '${place.going} going · ${friends.length} friend${friends.length == 1 ? '' : 's'}' : '${place.going} going'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _GoingPill(
              going: going,
              onTap: () => requireAccountThen(context, store, () async {
                final err = await store.togglePlaceRsvp(p.id);
                if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoingPill extends StatelessWidget {
  final bool going;
  final VoidCallback onTap;
  const _GoingPill({required this.going, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: going ? tokens.orange : tokens.raised,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(going ? Icons.check_rounded : Icons.add_rounded, size: 16, color: going ? tokens.onOrange : tokens.ink),
            const SizedBox(width: 3),
            Text(going ? 'Going' : 'Going?', style: TextStyle(color: going ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w800, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

/// An upcoming event post in the Upcoming list.
class _UpcomingPostCard extends StatelessWidget {
  final Post post;
  const _UpcomingPostCard({required this.post});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final going = post.going.contains('me');
    final badge = postOrgBadge(post);
    final photo = post.photoUrls.isNotEmpty ? post.photoUrls.first : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: post.id))),
      child: FunkyCard(
        margin: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 78,
                height: 96,
                child: OrgBadgeCorner(
                  badge: badge,
                  small: true,
                  inset: 4,
                  child: photo != null
                      ? Image.network(photo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => ColoredBox(color: tokens.raised))
                      : ColoredBox(color: tokens.raised, child: const Center(child: Text('🎉', style: TextStyle(fontSize: 30)))),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(post.eventTitle ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                  const SizedBox(height: 3),
                  Text(whenLabel(post.eventAt!), style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 2),
                  Text(
                    [if (post.placeName != null) post.placeName!, if (post.eventCover != null && post.eventCover!.isNotEmpty) post.eventCover!].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                  const SizedBox(height: 6),
                  Text(post.going.isEmpty ? 'Be the first going' : '${post.going.length} going',
                      style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _GoingPill(
              going: going,
              onTap: () => requireAccountThen(context, store, () async {
                final err = await store.toggleEventGoing(post.id);
                if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
              }),
            ),
          ],
        ),
      ),
    );
  }
}
