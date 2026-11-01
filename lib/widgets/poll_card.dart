import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ios_ui.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/session.dart';
import 'avatar_preview.dart';
import 'ui_widgets.dart';

/// One poll in your area, laid out like a post: who asked and when, then
/// the question and the options as tap-to-vote pills with their share, and
/// "58 votes · Ends in 3h". Used on Home and the full "Polls near you" list.
class PollCard extends StatelessWidget {
  final Poll poll;
  const PollCard({super.key, required this.poll});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final counts = store.pollCounts(poll);
    final mine = store.me.votes[poll.id];
    final total = counts.fold<int>(0, (a, b) => a + b);
    final person = store.personById(poll.by);
    final handle = person?.handle ?? 'someone';
    final canDelete = poll.by == 'me' || store.isAdmin;

    Widget pill(int i) {
      final share = total == 0 ? 0.0 : counts[i] / total;
      final picked = mine == i;
      final pct = '${(share * 100).round()}%';
      return GestureDetector(
        onTap: () => store.votePoll(poll.id, i),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 46,
            color: picked ? tokens.brand.withValues(alpha: 0.16) : tokens.raised,
            child: Stack(
              children: [
                // How much of the vote this option has.
                if (mine != null || total > 0)
                  FractionallySizedBox(
                    widthFactor: share.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: Container(color: picked ? tokens.brand : tokens.line.withValues(alpha: 0.9)),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          maskBadWords(poll.options[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: picked && share > 0.45 ? tokens.onOrange : tokens.ink,
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      if (picked) ...[
                        Icon(Icons.check_circle_rounded, size: 18, color: share > 0.6 ? tokens.onOrange : tokens.brand),
                        const SizedBox(width: 6),
                      ],
                      if (mine != null || total > 0)
                        Text(pct, style: TextStyle(color: picked ? tokens.brand : tokens.mute, fontWeight: FontWeight.w800, fontSize: 13.5)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final options = poll.options.length == 2
        ? Row(children: [Expanded(child: pill(0)), const SizedBox(width: 8), Expanded(child: pill(1))])
        : Column(
            children: [
              for (var i = 0; i < poll.options.length; i++) ...[
                if (i > 0) const SizedBox(height: 7),
                pill(i),
              ],
            ],
          );

    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => openProfile(context, poll.by),
                child: person != null ? PersonAvatar(person: person, size: 42, preview: false) : FunkyAvatar(seed: poll.by, label: '?', size: 42),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openProfile(context, poll.by),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                      Text(timeAgoLabel(poll.t), style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
              if (canDelete)
                IconButton(
                  tooltip: 'More',
                  onPressed: () => confirmDeletePoll(context, store, poll),
                  icon: Icon(Icons.more_horiz, color: tokens.mute),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: tokens.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(maskBadWords(poll.q), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 10),
                options,
                const SizedBox(height: 9),
                Text(
                  '${total == 1 ? '1 vote' : '$total votes'} · Ends in ${untilReset()}',
                  style: TextStyle(color: tokens.mute, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
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
  if (ok == true) store.deletePoll(poll.id);
}
