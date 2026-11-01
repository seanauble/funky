import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';

/// Settings → Blocked accounts: everyone you've blocked, with Unblock.
class BlockedAccountsScreen extends StatelessWidget {
  const BlockedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final blocked = store.blockedPeople;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Blocked accounts')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            "People you block can't message you, friend you or comment on your posts, and you won't see each other's posts, stories or chat.",
            style: TextStyle(color: tokens.mute, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (blocked.isEmpty)
            const EmptyNote(text: "You haven't blocked anyone.")
          else
            for (final p in blocked)
              FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    PersonAvatar(person: p, size: 38, preview: false),
                    const SizedBox(width: 12),
                    Expanded(child: Text('@${p.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800))),
                    TextButton(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final err = await store.unblockUser(p.id);
                        messenger.showSnackBar(SnackBar(content: Text(err ?? 'Unblocked @${p.handle}.')));
                      },
                      child: Text('Unblock', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
