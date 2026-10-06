import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'add_friends_screen.dart';

/// Reached from Settings, only ever shown to the one hardcoded FUNKY Admin
/// account (store.isAdmin — see app_store.dart) — a single place for the
/// moderation actions that used to be scattered one-at-a-time across
/// Places/Chat/a person's own profile: ban/unban a user (via search),
/// delete a place, delete a poll, and a one-tap "max out my points" for
/// testing the points/levels/badges UI without actually grinding for it.
class AdminPanelScreen extends StatelessWidget {
  const AdminPanelScreen({super.key});

  Future<void> _confirmDelete(
    BuildContext context,
    ThemeTokens tokens, {
    required String title,
    required String body,
    required VoidCallback onConfirm,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text(title, style: TextStyle(color: tokens.ink)),
        content: Text(body, style: TextStyle(color: tokens.mute)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Delete', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) onConfirm();
  }

  /// Tests every table/function the app depends on and lists what's missing,
  /// so "check your connection" never hides a SQL file that wasn't run.
  Future<void> _runBackendCheck(BuildContext context, ThemeTokens tokens, AppStore store) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final results = await store.checkBackend();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    final allOk = results.every((r) => r.$2);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text(allOk ? 'Backend is set up ✓' : 'Backend needs attention', style: TextStyle(color: tokens.ink)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in results)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r.$2 ? '✅' : '❌'} ${r.$1}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                      if (!r.$2 && r.$3.isNotEmpty) Text(r.$3, style: TextStyle(color: tokens.mute, fontSize: 11.5)),
                    ],
                  ),
                ),
              if (!allOk)
                Text(
                  'Run supabase/RUN_ALL.sql in the Supabase SQL Editor, then check again.',
                  style: TextStyle(color: tokens.brand, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (!store.isAdmin) {
      // Shouldn't be reachable — Settings only ever links here for an
      // admin account in the first place — but guard anyway rather than
      // trust the caller.
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('FUNKY Admin')),
        body: Padding(padding: const EdgeInsets.all(20), child: Text('Admin only.', style: TextStyle(color: tokens.ink))),
      );
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('FUNKY Admin')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const SectionHeader(title: 'Your account'),
          FunkyCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('Points: ${store.me.points}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: store.maxOutMyPoints,
                  child: Text('Max out', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const SectionHeader(title: 'Backend'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => _runBackendCheck(context, tokens, store),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('Check backend setup', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                    Icon(Icons.fact_check_outlined, color: tokens.mute),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader(title: 'Users'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddFriendsScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Find a user to ban/unban', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    Icon(Icons.search, color: tokens.mute),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'To give someone points, open their profile — the +100 / +500 / +1000 buttons are right under Add Friend.',
              style: TextStyle(color: tokens.mute, fontSize: 12.5),
            ),
          ),
          if (store.allBannedIds.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: EmptyNote(text: 'No one is banned right now.'))
          else
            ...store.allBannedIds.map((id) {
              final handle = store.personById(id)?.handle ?? id;
              return FunkyCard(
                margin: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Expanded(child: Text('@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                    TextButton(
                      onPressed: () => store.unbanUser(id),
                      child: Text('Unban', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              );
            }),
          const SectionHeader(title: 'Places'),
          if (store.places.isEmpty)
            const EmptyNote(text: 'No places right now.')
          else
            ...store.places.map((p) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                            Text(p.address, style: TextStyle(color: tokens.mute, fontSize: 12)),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => _confirmDelete(
                          context,
                          tokens,
                          title: 'Delete ${p.name}?',
                          body: 'This permanently removes this place, its reports, and its confirmations for everyone.',
                          onConfirm: () => store.deletePlace(p.id),
                        ),
                        icon: Icon(Icons.delete_outline, color: tokens.danger),
                      ),
                    ],
                  ),
                )),
          const SectionHeader(title: 'Polls'),
          if (store.polls.isEmpty)
            const EmptyNote(text: 'No polls right now.')
          else
            ...store.polls.map((poll) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(child: Text(poll.q, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                      IconButton(
                        onPressed: () => _confirmDelete(
                          context,
                          tokens,
                          title: 'Delete this poll?',
                          body: 'This permanently removes "${poll.q}" and everyone\'s votes on it.',
                          onConfirm: () => store.deletePoll(poll.id),
                        ),
                        icon: Icon(Icons.delete_outline, color: tokens.danger),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}
