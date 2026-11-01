import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../widgets/kind_picker.dart';
import '../widgets/poll_card.dart';
import '../widgets/ui_widgets.dart';
import 'create_sheet.dart';

/// Every poll in your area tonight, most-voted first — opened from
/// "View all polls" under Home's top 3.
class AllPollsScreen extends StatelessWidget {
  const AllPollsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final polls = store.rankedVisiblePolls;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Text(store.areaName != null ? 'Polls near ${store.areaName}' : 'Polls near you'),
        actions: [
          TextButton(
            onPressed: () => showCreateSheet(context, initial: CreateKind.poll),
            child: Text('Ask a poll', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: polls.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: EmptyNote(text: 'No polls in your area tonight. Ask the first one.'),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '${polls.length == 1 ? '1 poll' : '${polls.length} polls'} within ${rangeLabel()} · most votes first',
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                ),
                for (final p in polls) PollCard(key: ValueKey(p.id), poll: p),
              ],
            ),
    );
  }
}
