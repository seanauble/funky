import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import 'poll_bars.dart';
import 'ui_widgets.dart';

/// One poll in your area: the question, the vote bars, and (for your own
/// poll, or for an admin) a delete button. Used on Home's top 3 and on the
/// full "Polls near you" list.
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
                  onTap: () => confirmDeletePoll(context, store, poll),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, bottom: 4),
                    child: Icon(Icons.delete_outline, size: 20, color: tokens.mute),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          PollBars(options: poll.options, counts: counts, selectedIndex: mine, onSelect: (i) => store.votePoll(poll.id, i)),
          const SizedBox(height: 6),
          Text(
            '${total == 1 ? '1 vote' : '$total votes'} · ${timeAgoLabel(poll.t)}',
            style: TextStyle(color: tokens.mute, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

Future<void> confirmDeletePoll(BuildContext context, AppStore store, Poll poll) async {
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
