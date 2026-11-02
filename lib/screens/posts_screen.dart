import '../widgets/ios_ui.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../services/media_cache.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/post_models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/kind_picker.dart';
import '../widgets/ui_widgets.dart';
import '../widgets/poll_card.dart' show CommentPreviewRow;
import '../widgets/org_badge.dart';
import 'account_screen.dart';
import 'create_sheet.dart';

/// One post, full size: who posted it and when, the photos (swipe through
/// them, double-tap to like) with the place pinned on top, the caption,
/// like / dislike / comment, and the newest two comments. A text-only post
/// is a question card with quick replies instead of photos.
class PostCard extends StatefulWidget {
  final Post post;
  // On the post's own page: full caption, no comment previews or link.
  final bool inDetail;
  const PostCard({super.key, required this.post, this.inDetail = false});

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  int _page = 0;
  bool _burst = false;
  Timer? _burstTimer;
  // Each first photo's real shape, so it shows uncropped (within limits).
  static final Map<String, double> _aspects = {};

  void _learnAspect(String url) {
    if (_aspects.containsKey(url)) return;
    _aspects[url] = 4 / 5;
    final stream = netImageProvider(url).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final h = info.image.height;
      if (h > 0) _aspects[url] = info.image.width / h;
      stream.removeListener(listener);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _burstTimer?.cancel();
    super.dispose();
  }

  void _openDetail() {
    if (widget.inDetail) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: widget.post.id)));
  }

  void _like(AppStore store, Post post, {bool onlyLike = false}) {
    requireAccountThen(context, store, () {
      final liked = post.likes.contains('me');
      if (onlyLike) {
        setState(() => _burst = true);
        _burstTimer?.cancel();
        _burstTimer = Timer(const Duration(milliseconds: 750), () {
          if (mounted) setState(() => _burst = false);
        });
        if (liked) return;
      }
      store.togglePostLike(post.id);
    });
  }

  void _dislike(AppStore store, Post post) {
    requireAccountThen(context, store, () async {
      final err = await store.togglePostDislike(post.id);
      if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    });
  }

  void _quickReply(AppStore store, Post post, String text) {
    requireAccountThen(context, store, () async {
      final err = await store.addComment(post.id, text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Replied "$text"')));
    });
  }

  Future<void> _menu(AppStore store, Post post) async {
    final mine = post.uid == 'me';
    final disliked = post.dislikes.contains('me');
    final choice = await showIosActionSheet<String>(
      context,
      actions: [
        if (!mine) const IosSheetAction('View profile', 'profile'),
        if (!mine) IosSheetAction(disliked ? 'Undo "Not for me"' : 'Not for me', 'dislike', icon: disliked ? Icons.thumb_down : Icons.thumb_down_outlined),
        if (!mine) const IosSheetAction('Report post', 'report'),
        if (mine || store.isAdmin) IosSheetAction(mine ? 'Delete post' : 'Delete post (Admin)', 'delete', destructive: true),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'profile') {
      openProfile(context, post.uid);
    } else if (choice == 'dislike') {
      _dislike(store, post);
    } else if (choice == 'delete') {
      await _confirmDelete(store, post);
    } else if (choice == 'report') {
      await _report(store, post);
    }
  }

  Future<void> _confirmDelete(AppStore store, Post post) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showIosDialog<bool>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text('Delete this post?'),
        content: const Text('It comes down for everyone, with its likes and comments.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await store.deletePost(post.id);
    messenger.showSnackBar(SnackBar(content: Text(err ?? 'Post deleted.')));
    if (err == null && widget.inDetail && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _report(AppStore store, Post post) async {
    final messenger = ScaffoldMessenger.of(context);
    final reason = await showIosActionSheet<String>(
      context,
      title: 'Report this post',
      message: 'Reports are private. The FUNKY team reviews every one.',
      actions: [for (final r in AppStore.storyReportReasons) IosSheetAction(r, r)],
    );
    if (reason == null) return;
    final msg = await store.reportPost(post, reason);
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final post = store.postById(widget.post.id) ?? widget.post;
    final person = store.personById(post.uid);
    final handle = person?.handle ?? 'someone';
    final liked = post.likes.contains('me');
    // A location only shows when the poster tagged a place — never the
    // spot they were standing in.
    final placeName = post.placeName;
    final hasPlace = placeName != null && placeName.isNotEmpty;
    final String? pinTitle = hasPlace ? placeName : null;
    final String? pinSub = hasPlace ? post.areaName : null;
    final tonightRank = store.tonightTopPosts[post.id];
    final wonRank = store.awardRankFor(post.id);
    final urls = post.photoUrls;
    final caption = post.caption.trim();
    final previews = widget.inDetail ? const <PostComment>[] : store.commentPreviewFor(post.id);

    Widget action(IconData icon, Color color, int? count, VoidCallback? onTap, String tip) => InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 25, semanticLabel: tip),
                if (count != null) ...[
                  const SizedBox(width: 5),
                  Text('$count', style: TextStyle(color: color == tokens.brand ? tokens.brand : tokens.ink, fontWeight: FontWeight.w700, fontSize: 15)),
                ],
              ],
            ),
          ),
        );

    // Quick replies on a question post: the busiest spots near you.
    final replies = <String>[
      for (final p in store.verifiedRankedPlaces.take(2)) '${p.name}?',
      'Still deciding',
    ];

    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Who + when
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openProfile(context, post.uid),
                  child: person != null
                      ? PersonAvatar(person: person, size: 40, preview: false)
                      : FunkyAvatar(seed: post.uid, label: '?', size: 40),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openProfile(context, post.uid),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        person != null
                            ? StyledName(person: person, text: '@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5))
                            : Text('@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                        Text(
                          post.isTextOnly && pinTitle != null ? '${timeAgoLabel(post.t)} · 📍 $pinTitle' : timeAgoLabel(post.t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tokens.mute, fontSize: 13),
                        ),
                        if (tonightRank != null || wonRank != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(color: tokens.orange.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
                              child: Text(
                                tonightRank != null
                                    ? '${topPostMedal(tonightRank)} #$tonightRank tonight · +${AppStore.topPostPoints[tonightRank - 1]} if it holds'
                                    : '🏆 #$wonRank post of the night',
                                style: TextStyle(color: tokens.orange, fontSize: 11.5, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  onPressed: () => _menu(store, post),
                  icon: Icon(Icons.more_horiz, color: tokens.mute),
                ),
              ],
            ),
          ),
          if (post.isTextOnly) ...[
            // A question card: big text + quick replies.
            GestureDetector(
              onTap: widget.inDetail ? null : _openDetail,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: filteredMessageText(caption, TextStyle(color: tokens.ink, fontSize: 19, fontWeight: FontWeight.w600, height: 1.25)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in replies)
                    ActionChip(
                      label: Text(r, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                      backgroundColor: tokens.raised,
                      side: BorderSide(color: tokens.line),
                      shape: const StadiumBorder(),
                      onPressed: () => _quickReply(store, post, r),
                    ),
                  if (!widget.inDetail)
                    ActionChip(
                      avatar: Icon(Icons.add, size: 18, color: tokens.ink),
                      label: Text('Add reply', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                      backgroundColor: tokens.surface,
                      side: BorderSide(color: tokens.line),
                      shape: const StadiumBorder(),
                      onPressed: _openDetail,
                    ),
                ],
              ),
            ),
          ] else ...[
            // Photos, with the place pinned on top.
            // Compact in the feed: wide photos show whole, anything taller
            // is cropped to 4:3 so a post takes about a third of the screen
            // and you can still see what's around it.
            if (urls.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  // On the post's own page it can be taller (up to 4:5).
                  aspectRatio: (_aspects[urls.first] ?? (widget.inDetail ? 1.0 : 4 / 3)).clamp(widget.inDetail ? 0.8 : 4 / 3, 1.91),
                  child: GestureDetector(
                    onDoubleTap: () => _like(store, post, onlyLike: true),
                    onTap: widget.inDetail ? null : _openDetail,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: tokens.raised,
                          child: PageView.builder(
                            itemCount: urls.length,
                            onPageChanged: (i) => setState(() => _page = i),
                            itemBuilder: (_, i) => netImage(
                              urls[i],
                              fit: BoxFit.cover,
                              frameBuilder: (context, child, frame, sync) {
                                if (frame != null && i == 0) _learnAspect(urls[i]);
                                return child;
                              },
                              loadingBuilder: (context, child, progress) => progress == null
                                  ? child
                                  : Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.mute))),
                              errorBuilder: (_, __, ___) => Center(child: Icon(Icons.broken_image_outlined, color: tokens.mute)),
                            ),
                          ),
                        ),
                        if (pinTitle != null)
                          Positioned(
                            top: 10,
                            left: 10,
                            right: 70,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(10)),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.location_on, color: Colors.white, size: 18),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(pinTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
                                          if (pinSub != null)
                                            Text(pinSub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (urls.length > 1)
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                              child: Text('${_page + 1}/${urls.length}', style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        IgnorePointer(
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _burst ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: AnimatedScale(
                                scale: _burst ? 1 : 0.6,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutBack,
                                child: const Icon(Icons.favorite, color: Colors.white, size: 96, shadows: [Shadow(blurRadius: 16, color: Colors.black38)]),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // The caption right under the photo.
            if (caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: filteredMessageText(
                  caption,
                  TextStyle(color: tokens.ink, fontSize: 15.5, height: 1.3),
                  maxLines: widget.inDetail ? null : 4,
                  overflow: widget.inDetail ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
              ),
            // An event: name, when, where and "I'm going".
            if (post.isEvent) EventBlock(post: post),
          ],
          // Like · comments · save ("Not for me" is in the ··· menu).
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 4, 0),
            child: Row(
              children: [
                action(liked ? Icons.favorite : Icons.favorite_border, liked ? tokens.brand : tokens.ink, post.likes.length, () => _like(store, post), liked ? 'Unlike' : 'Like'),
                const SizedBox(width: 6),
                action(Icons.chat_bubble_outline_rounded, tokens.ink, post.commentCount, widget.inDetail ? null : _openDetail, 'Comments'),
                const Spacer(),
                if (urls.length > 1)
                  for (var i = 0; i < urls.length; i++)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: i == _page ? tokens.orange : tokens.line),
                    ),
                IconButton(
                  tooltip: store.isPostSaved(post.id) ? 'Saved' : 'Save',
                  onPressed: () => store.toggleSavePost(post.id),
                  icon: Icon(store.isPostSaved(post.id) ? Icons.bookmark : Icons.bookmark_border, color: store.isPostSaved(post.id) ? tokens.brand : tokens.ink, size: 26),
                ),
              ],
            ),
          ),
          // The newest two comments.
          for (final c in previews) CommentPreviewRow(comment: c, onTap: _openDetail),
          if (!widget.inDetail && post.commentCount > previews.length)
            GestureDetector(
              onTap: _openDetail,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
                child: Text(
                  post.commentCount == 1 ? 'View 1 comment' : 'View all ${post.commentCount} comments',
                  style: TextStyle(color: tokens.mute, fontSize: 13),
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// A two-column, staggered grid of posts (photos at different heights,
/// question posts as colored cards) — Home's posts sections.
class PostsGrid extends StatelessWidget {
  final List<Post> posts;
  const PostsGrid({super.key, required this.posts});

  static const _ratios = [0.8, 1.0, 0.75, 0.9];

  static double ratioFor(Post p) => _ratios[p.id.hashCode.abs() % _ratios.length];

  @override
  Widget build(BuildContext context) {
    final top = context.watch<AppStore>().tonightTopPosts;
    final left = <Post>[];
    final right = <Post>[];
    var hl = 0.0;
    var hr = 0.0;
    for (final p in posts) {
      // Rough height in "column widths", so the two columns stay even.
      final h = p.photoUrls.isEmpty ? (p.isEvent ? 0.9 : 0.75) : 1 / ratioFor(p) + 0.35;
      if (hl <= hr) {
        left.add(p);
        hl += h;
      } else {
        right.add(p);
        hr += h;
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: [for (final p in left) PostTile(key: ValueKey('tile_${p.id}'), post: p, rank: top[p.id])])),
        const SizedBox(width: 10),
        Expanded(child: Column(children: [for (final p in right) PostTile(key: ValueKey('tile_${p.id}'), post: p, rank: top[p.id])])),
      ],
    );
  }
}

/// One tile in [PostsGrid]: the cover photo with where it was and its 🔥
/// score, or a question card. Tap to open the post.
class PostTile extends StatelessWidget {
  final Post post;
  // 1, 2 or 3 if it's one of tonight's top posts near you.
  final int? rank;
  const PostTile({super.key, required this.post, this.rank});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final p = store.postById(post.id) ?? post;
    final person = store.personById(p.uid);
    final handle = person?.handle ?? 'someone';
    void open() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: p.id)));
    final score = p.score;
    final scoreBadge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(score < 0 ? Icons.thumb_down_outlined : Icons.local_fire_department, color: score < 0 ? tokens.mute : tokens.orange, size: 18),
        const SizedBox(width: 2),
        Text('${score.abs()}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
      ],
    );

    if (p.isTextOnly) {
      return GestureDetector(
        onTap: open,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: tokens.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(maskBadWords(p.caption.trim()), maxLines: 5, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 12),
              Row(
                children: [
                  person != null ? PersonAvatar(person: person, size: 26, preview: false) : FunkyAvatar(seed: p.uid, label: '?', size: 26),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(handle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 12)),
                        Text(timeAgoLabel(p.t), style: TextStyle(color: tokens.mute, fontSize: 11)),
                      ],
                    ),
                  ),
                  Icon(Icons.mode_comment_outlined, color: tokens.mute, size: 16),
                  const SizedBox(width: 3),
                  Text('${p.commentCount}', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final ev = p.isEvent;
    if (ev && p.photoUrls.isEmpty) {
      // An event without a photo: a flyer card.
      return GestureDetector(
        onTap: open,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: eventTint, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(eventWhenLabel(p.eventAt!).toUpperCase(),
                        style: TextStyle(color: tokens.mute, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  ),
                  if (postOrgBadge(p) != null) OrgLettersBadge(badge: postOrgBadge(p)!, small: true),
                ],
              ),
              const SizedBox(height: 6),
              Text(maskBadWords(p.eventTitle!), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 21, fontWeight: FontWeight.w900, height: 1.1)),
              const SizedBox(height: 8),
              if (p.placeName != null && p.placeName!.isNotEmpty)
                Text('📍 ${p.placeName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text(
                [if (p.eventCover != null) p.eventCover!, '${p.going.length} going'].join(' · '),
                style: TextStyle(color: tokens.mute, fontSize: 12.5),
              ),
            ],
          ),
        ),
      );
    }
    final placeName = p.placeName;
    final title = ev ? maskBadWords(p.eventTitle!) : (placeName != null && placeName.isNotEmpty ? placeName : '@$handle');
    // Only a tagged place counts as a location.
    final sub = placeName != null && placeName.isNotEmpty && !ev ? '@$handle · ${timeAgoLabel(p.t)}' : timeAgoLabel(p.t);
    final medal = rank;
    return GestureDetector(
      onTap: open,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: PostsGrid.ratioFor(p),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    netImage(
                      p.photoUrls.first,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) => progress == null ? child : Container(color: tokens.raised),
                      errorBuilder: (_, __, ___) => Container(color: tokens.raised, child: Icon(Icons.broken_image_outlined, color: tokens.mute)),
                    ),
                    // The frat/school letters an event is for, top right.
                    if (postOrgBadge(p) != null)
                      Positioned(top: 7, right: 7, child: OrgLettersBadge(badge: postOrgBadge(p)!, small: true))
                    else if (p.photoUrls.length > 1)
                      const Positioned(top: 8, right: 8, child: Icon(Icons.collections_rounded, color: Colors.white, size: 18, shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
                    if (medal != null && !ev)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(8)),
                          child: Text('${topPostMedal(medal)} #$medal tonight', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    if (ev)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(8)),
                          child: Text(eventWhenLabel(p.eventAt!), style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 14.5)),
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  scoreBadge,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 🥇 🥈 🥉 for tonight's top 3 posts.
String topPostMedal(int rank) => rank == 1 ? '🥇' : (rank == 2 ? '🥈' : '🥉');

/// The background for event cards (a soft purple).
const Color eventTint = Color(0x248B5CF6);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Tonight · 9 PM", "Tomorrow · 8:30 PM", "Fri, May 23 · 8 PM".
String eventWhenLabel(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute == 0 ? '' : ':${d.minute.toString().padLeft(2, '0')}';
  final ap = d.hour < 12 ? 'AM' : 'PM';
  final now = DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  final String day;
  if (days == 0) {
    day = d.hour >= 17 ? 'Tonight' : 'Today';
  } else if (days == 1) {
    day = 'Tomorrow';
  } else {
    day = '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
  }
  return '$day · $h$m $ap';
}

/// The event part of a post: a little calendar date, the name, when,
/// where and the cover, and the "I'm going" button with who's going.
class EventBlock extends StatelessWidget {
  final Post post;
  const EventBlock({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final p = store.postById(post.id) ?? post;
    final at = p.eventAt!;
    final going = p.going.contains('me');
    final friends = store.friendsGoingTo(p);
    final where = [
      if (p.placeName != null && p.placeName!.isNotEmpty) p.placeName!,
      if (p.eventCover != null && p.eventCover!.trim().isNotEmpty) p.eventCover!.trim(),
    ].join(' · ');
    final over = at.isBefore(DateTime.now().subtract(const Duration(hours: 6)));
    final count = [
      p.going.length == 1 ? '1 going' : '${p.going.length} going',
      if (friends.isNotEmpty) friends.length == 1 ? '@${friends.first.handle} too' : '${friends.length} friends',
    ].join(' · ');
    final onColor = going ? tokens.onOrange : tokens.ink;

    // Same clean card as a poll: white with a thin border, then one wide
    // "I'm going" bar.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 50,
                decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(11)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_months[at.month - 1].toUpperCase(), style: TextStyle(color: tokens.orange, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                    Text('${at.day}', style: TextStyle(color: tokens.ink, fontSize: 20, fontWeight: FontWeight.w900, height: 1.05)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(maskBadWords(p.eventTitle!), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800, height: 1.15)),
                    const SizedBox(height: 2),
                    Text(eventWhenLabel(at), style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 13.5)),
                    if (where.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.location_on_outlined, size: 14, color: tokens.mute),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: over
                ? null
                : () => requireAccountThen(context, store, () async {
                      final err = await store.toggleEventGoing(p.id);
                      if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: going ? tokens.brand : tokens.raised,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    over ? Icons.event_busy_outlined : (going ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded),
                    size: 20,
                    color: over ? tokens.mute : (going ? tokens.onOrange : tokens.brand),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    over ? 'Ended' : (going ? "You're going" : "I'm going"),
                    style: TextStyle(color: over ? tokens.mute : onColor, fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      count,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: going ? tokens.onOrange.withValues(alpha: 0.9) : tokens.mute, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A sideways row of upcoming event cards (Home). Tap one to open it.
class UpcomingEventsStrip extends StatelessWidget {
  final List<Post> events;
  const UpcomingEventsStrip({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: events.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final p = events[i];
          return GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: p.id))),
            child: Container(
              width: 200,
              decoration: BoxDecoration(color: eventTint, borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 104,
                    width: double.infinity,
                    child: p.photoUrls.isNotEmpty
                        ? netImage(
                            p.photoUrls.first,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(color: tokens.raised),
                          )
                        : Container(
                            alignment: Alignment.center,
                            child: Icon(Icons.celebration_rounded, color: tokens.orange, size: 40),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(eventWhenLabel(p.eventAt!).toUpperCase(),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.orange, fontSize: 10.5, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(maskBadWords(p.eventTitle!),
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 15.5, fontWeight: FontWeight.w800, height: 1.15)),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (p.placeName != null && p.placeName!.isNotEmpty) p.placeName!,
                            '${p.going.length} going',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tokens.mute, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Every post in your area (or your friends' posts), most liked first.
class PostsFeedScreen extends StatelessWidget {
  // Your friends' posts from anywhere instead of everyone's in your area.
  final bool friends;
  // Only posts tagged at these kinds of places (null = all).
  final Set<PlaceKind>? kinds;
  final String? title;
  // One person's posts (newest first), or the posts tagged at one place.
  final String? byUid;
  final String? placeId;
  // Posts you bookmarked.
  final bool saved;
  const PostsFeedScreen({super.key, this.friends = false, this.kinds, this.title, this.byUid, this.placeId, this.saved = false});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final wanted = kinds;
    final uid = byUid;
    final at = placeId;
    final List<Post> posts;
    if (saved) {
      posts = store.savedPosts;
    } else if (uid != null) {
      posts = store.postsBy(uid);
    } else if (at != null) {
      posts = store.rankPosts(store.postsAt(at));
    } else {
      final base = friends ? store.friendsPosts : store.postsNearby;
      posts = store.rankPosts(base.where((p) => wanted == null || wanted.contains(store.postPlaceKind(p))));
    }
    final heading = title ?? (friends ? "Friends' posts" : (store.areaName != null ? 'Posts near ${store.areaName}' : 'Posts near you'));
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Text(heading),
        actions: [
          IconButton(
            tooltip: 'New post',
            onPressed: () => showCreateSheet(context, initial: CreateKind.post),
            icon: Icon(Icons.add_box_outlined, color: tokens.orange),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: store.refreshPosts,
        child: posts.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  EmptyNote(text: store.postsLoaded ? 'No posts here yet. Share a few pics or ask something.' : 'Loading posts…'),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: posts.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(uid != null ? 'Newest first' : 'Most liked first', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    );
                  }
                  final p = posts[i - 1];
                  return PostCard(key: ValueKey(p.id), post: p);
                },
              ),
      ),
    );
  }
}

/// One post with all its comments and a box to add yours.
class PostDetailScreen extends StatefulWidget {
  final String postId;
  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _loading = true;
  bool _sending = false;
  PostComment? _replyTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = context.read<AppStore>();
      await store.ensurePost(widget.postId);
      await store.fetchComments(widget.postId);
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(AppStore store) {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    requireAccountThen(context, store, () async {
      setState(() => _sending = true);
      final err = await store.addComment(widget.postId, text, replyTo: _replyTo?.id);
      if (!mounted) return;
      setState(() => _sending = false);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _controller.clear();
      setState(() => _replyTo = null);
    });
  }

  void _startReply(AppStore store, PostComment c) {
    final handle = store.personById(c.uid)?.handle;
    setState(() => _replyTo = c);
    // Start the reply with their @ so it's clear who you're answering.
    if (handle != null && c.uid != 'me' && !_controller.text.contains('@$handle')) {
      _controller.text = '@$handle ${_controller.text}';
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    }
    _focus.requestFocus();
  }

  Future<void> _like(AppStore store, PostComment c) async {
    final err = await store.toggleCommentLike(c);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  /// Comments in threads: each top-level comment, then the replies to it
  /// (and replies to those), oldest first.
  List<(PostComment, bool)> _threaded(List<PostComment> comments) {
    final byId = {for (final c in comments) c.id: c};
    String rootOf(PostComment c) {
      var cur = c;
      var hops = 0;
      while (cur.replyTo != null && byId.containsKey(cur.replyTo) && hops < 20) {
        cur = byId[cur.replyTo]!;
        hops++;
      }
      return cur.id;
    }

    final replies = <String, List<PostComment>>{};
    final tops = <PostComment>[];
    for (final c in comments) {
      final root = rootOf(c);
      if (root == c.id) {
        tops.add(c);
      } else {
        (replies[root] ??= []).add(c);
      }
    }
    return [
      for (final t in tops) ...[
        (t, false),
        for (final r in replies[t.id] ?? const <PostComment>[]) (r, true),
      ],
    ];
  }

  Future<void> _deleteComment(AppStore store, PostComment c) async {
    final ok = await showIosDialog<bool>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text('Delete this comment?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) await store.deleteComment(c);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final post = store.postById(widget.postId);
    final comments = store.commentsFor(widget.postId);

    return Scaffold(
      backgroundColor: tokens.bg,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Post')),
      body: post == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator.adaptive()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("This post isn't around anymore.", style: TextStyle(color: tokens.mute)),
                    ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      PostCard(post: post, inDetail: true),
                      Text(
                        comments.isEmpty ? (_loading ? 'Loading comments…' : 'No comments yet. Say something.') : 'Comments',
                        style: TextStyle(color: comments.isEmpty ? tokens.mute : tokens.ink, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      for (final (c, isReply) in _threaded(comments))
                        _CommentRow(
                          comment: c,
                          isReply: isReply,
                          canDelete: c.uid == 'me' || post.uid == 'me' || store.isAdmin,
                          onDelete: () => _deleteComment(store, c),
                          onReply: () => requireAccountThen(context, store, () => _startReply(store, c)),
                          onLike: () => requireAccountThen(context, store, () => _like(store, c)),
                        ),
                    ],
                  ),
                ),
                ComposerArea(
                  color: tokens.surface,
                  border: Border(top: BorderSide(color: tokens.line)),
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Column(
                     mainAxisSize: MainAxisSize.min,
                     children: [
                      if (_replyTo != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Replying to @${_replyTo!.uid == 'me' ? store.myChatHandle : (store.personById(_replyTo!.uid)?.handle ?? 'someone')}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700),
                                ),
                              ),
                              GestureDetector(
                                onTap: () => setState(() => _replyTo = null),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Icon(Icons.close_rounded, size: 18, color: tokens.mute),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            maxLength: AppStore.maxCommentLength,
                            minLines: 1,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: _replyTo != null ? 'Write a reply…' : 'Add a comment…',
                              hintStyle: TextStyle(color: tokens.mute),
                              filled: true,
                              fillColor: tokens.raised,
                              counterText: '',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                            ),
                            style: TextStyle(color: tokens.ink),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Send',
                          onPressed: _sending ? null : () => _send(store),
                          icon: _sending
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                              : Icon(Icons.send_rounded, color: tokens.orange),
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

class _CommentRow extends StatelessWidget {
  final PostComment comment;
  final bool isReply;
  final bool canDelete;
  final VoidCallback onDelete;
  final VoidCallback onReply;
  final VoidCallback onLike;
  const _CommentRow({
    required this.comment,
    required this.canDelete,
    required this.onDelete,
    required this.onReply,
    required this.onLike,
    this.isReply = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(comment.uid);
    final handle = comment.uid == 'me' ? store.myChatHandle : (person?.handle ?? 'someone');
    final size = isReply ? 24.0 : 30.0;
    final meta = TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w700);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: canDelete ? onDelete : null,
      onDoubleTap: comment.likedByMe ? null : onLike,
      child: Padding(
        padding: EdgeInsets.only(bottom: 14, left: isReply ? 40 : 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openProfile(context, comment.uid),
              child: person != null
                  ? PersonAvatar(person: person, size: size, preview: false)
                  : FunkyAvatar(seed: comment.uid, label: '?', size: size),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '@$handle ', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                    TextSpan(text: maskBadWords(comment.text), style: TextStyle(color: tokens.ink)),
                  ])),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(timeAgoLabel(comment.t), style: TextStyle(color: tokens.mute, fontSize: 12)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onReply,
                        child: Text('Reply', style: meta),
                      ),
                      if (canDelete) ...[
                        const SizedBox(width: 12),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onDelete,
                          child: Text('Delete', style: meta),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onLike,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, top: 2, right: 2),
                child: Column(
                  children: [
                    Icon(
                      comment.likedByMe ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      size: 16,
                      color: comment.likedByMe ? tokens.brand : tokens.mute,
                    ),
                    if (comment.likes > 0)
                      Text('${comment.likes}', style: TextStyle(color: tokens.mute, fontSize: 10.5, fontWeight: FontWeight.w700)),
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
