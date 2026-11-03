import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ios_ui.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/post_models.dart';
import '../data/session.dart';
import '../screens/poll_comments_screen.dart';
import 'avatar_preview.dart';
import 'ui_widgets.dart';

/// One poll in your area, laid out like a post: who asked and when, then a
/// clean card with the question, the answers as tap-to-vote bars (your pick
/// fills in orange with its share), "58 votes · Ends in 3h", and the newest
/// comments under it. Used on Home, the Polls list and the poll's own page.
class PollCard extends StatelessWidget {
  final Poll poll;
  // On the poll's own page: no comment previews or "add a comment" link.
  final bool inDetail;
  const PollCard({super.key, required this.poll, this.inDetail = false});

  /// A little icon for an answer that's a spot near you (or "Staying in").
  static IconData? iconFor(AppStore store, String option) {
    final o = option.trim().toLowerCase();
    if (o == 'staying in' || o == 'stay in') return Icons.home_rounded;
    for (final p in store.places) {
      if (p.name.trim().toLowerCase() == o) {
        return switch (p.kind) {
          PlaceKind.bar => Icons.local_bar_rounded,
          PlaceKind.club => Icons.nightlife_rounded,
          PlaceKind.party => Icons.celebration_rounded,
          PlaceKind.event => Icons.confirmation_number_outlined,
          PlaceKind.tailgate => Icons.sports_football_rounded,
          PlaceKind.frat => Icons.account_balance_rounded,
          PlaceKind.area => Icons.place_outlined,
        };
      }
    }
    return null;
  }

  void _open(BuildContext context) {
    if (inDetail) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PollCommentsScreen(pollId: poll.id)));
  }

  Future<void> _menu(BuildContext context, AppStore store) async {
    final mine = poll.by == 'me';
    final choice = await showIosActionSheet<String>(
      context,
      actions: [
        if (!mine) const IosSheetAction('View profile', 'profile'),
        if (mine || store.isAdmin) IosSheetAction(mine ? 'Delete poll' : 'Delete poll (Admin)', 'delete', destructive: true),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'profile') openProfile(context, poll.by);
    if (choice == 'delete') await confirmDeletePoll(context, store, poll);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final counts = store.pollCounts(poll);
    final mine = store.me.votes[poll.id];
    final voted = mine != null;
    final total = counts.fold<int>(0, (a, b) => a + b);
    final person = store.personById(poll.by);
    final handle = person?.handle ?? 'someone';
    final comments = store.pollCommentsFor(poll.id);
    final previews = inDetail ? const <PostComment>[] : store.pollCommentPreview(poll.id);
    final canComment = store.canCommentOnPoll(poll.id);

    Widget pill(int i) {
      final share = total == 0 ? 0.0 : counts[i] / total;
      final picked = mine == i;
      final icon = iconFor(store, poll.options[i]);
      final pct = '${(share * 100).round()}%';

      Widget content({required bool onFill}) {
        final fg = onFill ? Colors.white : (picked ? tokens.brand : tokens.ink);
        final pctColor = onFill ? Colors.white : (picked ? tokens.brand : tokens.mute);
        return Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 19, color: fg),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      maskBadWords(poll.options[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                  if (picked) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 19,
                      height: 19,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: onFill ? Colors.white : tokens.brand, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded, size: 14, color: onFill ? tokens.brand : Colors.white),
                    ),
                  ],
                ],
              ),
            ),
            if (voted) ...[
              const SizedBox(width: 8),
              Text(pct, style: TextStyle(color: pctColor, fontWeight: FontWeight.w800, fontSize: 14.5)),
            ],
          ],
        );
      }

      return GestureDetector(
        onTap: () => store.votePoll(poll.id, i),
        child: Container(
          height: 48,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: picked ? tokens.brand.withValues(alpha: 0.14) : tokens.raised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              return TweenAnimationBuilder<double>(
                tween: Tween(end: picked ? share.clamp(0.0, 1.0) : 0.0),
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOutCubic,
                builder: (context, f, _) {
                  final fillW = w * f;
                  return Stack(
                    children: [
                      if (fillW > 0) Positioned(left: 0, top: 0, bottom: 0, width: fillW, child: ColoredBox(color: tokens.brand)),
                      Positioned.fill(
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: content(onFill: false)),
                      ),
                      // The same words in white, only where the orange is.
                      if (fillW > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: fillW,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: w,
                              maxWidth: w,
                              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: content(onFill: true)),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      );
    }

    final options = poll.options.length == 2
        ? Row(children: [Expanded(child: pill(0)), const SizedBox(width: 10), Expanded(child: pill(1))])
        : Column(
            children: [
              for (var i = 0; i < poll.options.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                pill(i),
              ],
            ],
          );

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
                  onTap: () => openProfile(context, poll.by),
                  child: person != null ? PersonAvatar(person: person, size: 40, preview: false) : FunkyAvatar(seed: poll.by, label: '?', size: 40),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openProfile(context, poll.by),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        person != null
                            ? StyledName(person: person, text: '@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5))
                            : Text('@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                        Text(timeAgoLabel(poll.t), style: TextStyle(color: tokens.mute, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  onPressed: () => _menu(context, store),
                  icon: Icon(Icons.more_horiz, color: tokens.mute),
                ),
              ],
            ),
          ),
          // The poll itself.
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: tokens.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(maskBadWords(poll.q), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 2),
                Text(voted ? 'Your vote is in · tap another to switch' : 'Tap to vote', style: TextStyle(color: tokens.mute, fontSize: 13.5)),
                const SizedBox(height: 12),
                options,
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (total > 0) ...[
                      AvatarStack(people: store.faceOrder(store.pollVoterIds(poll)), total: total, size: 22),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        '${total == 1 ? '1 vote' : '$total votes'} · Ends in ${untilReset()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tokens.mute, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!inDetail) ...[
            const SizedBox(height: 10),
            for (final c in previews) CommentPreviewRow(comment: c, onTap: () => _open(context)),
            if (canComment)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _open(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                  child: Text(
                    comments.length > previews.length ? 'View all ${comments.length} comments' : 'Add a comment…',
                    style: TextStyle(color: tokens.mute, fontSize: 13.5),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// One comment under a post or poll: avatar, @handle (in color) and the
/// comment, with how long ago under it.
class CommentPreviewRow extends StatelessWidget {
  final PostComment comment;
  final VoidCallback? onTap;
  const CommentPreviewRow({super.key, required this.comment, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(comment.uid);
    final handle = comment.uid == 'me' ? store.myChatHandle : (person?.handle ?? 'someone');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            person != null ? PersonAvatar(person: person, size: 32, preview: false) : FunkyAvatar(seed: comment.uid, label: '?', size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '@$handle ', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                      TextSpan(text: maskBadWords(comment.text), style: TextStyle(color: tokens.ink)),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(timeAgoLabel(comment.t), style: TextStyle(color: tokens.mute, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> confirmDeletePoll(BuildContext context, AppStore store, Poll poll) async {
  final ok = await showIosDialog<bool>(
    context: context,
    builder: (ctx) => IosAlert(
      title: const Text('Delete this poll?'),
      content: Text('This removes "${poll.q}" and everyone\'s votes on it.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ),
  );
  if (ok != true) return;
  final err = await store.deletePoll(poll.id);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Poll deleted.')));
}
