import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/notification_models.dart';
import '../widgets/ui_widgets.dart';
import '../root_shell.dart';
import 'account_screen.dart';
import 'dm_thread_screen.dart';
import 'friend_requests_screen.dart';
import 'group_thread_screen.dart';
import 'place_detail_screen.dart';

/// Opened from the bell. Newest first: new DMs, friend requests, new
/// verified places near you, and reports at the place you're going to
/// tonight. Tapping one marks it read and jumps to the right screen.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  Future<void> _open(BuildContext context, AppStore store, AppNotification n) async {
    final navigator = Navigator.of(context);
    unawaited(store.markNotificationRead(n.id));
    switch (n.kind) {
      case 'dm':
        final from = n.data['from'] as String?;
        if (from == null) return;
        await store.ensurePerson(from);
        navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
      case 'group':
        final groupId = n.data['group_id'] as String?;
        if (groupId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => GroupThreadScreen(groupId: groupId)));
      case 'friend':
        navigator.push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen()));
      case 'mention':
        // Back out to the main tabs and land on Chat.
        navigator.popUntil((route) => route.isFirst);
        rootShellTabRequest.value = 1;
      case 'place':
      case 'report':
      case 'photo':
        final placeId = n.data['place_id'] as String?;
        if (placeId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final items = store.notifications;
    final pending = store.pendingFriendRequestCount;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: const Text('Notifications'),
        actions: [
          if (store.unreadNotificationCount > 0)
            TextButton(
              onPressed: store.markAllNotificationsRead,
              child: Text('Mark all read', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
            ),
          if (items.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'clear') store.clearAllNotifications();
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Clear all'))],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.people_outline, color: tokens.ink),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        pending > 0 ? 'Friends & requests ($pending waiting)' : 'Friends & requests',
                        style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text('›', style: TextStyle(color: tokens.mute)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (!store.signedIn)
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Create an account to get notifications', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text("Messages, friend requests, new verified places near you, and updates at the places you're going to.", style: TextStyle(color: tokens.mute)),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
                    child: const Text('Create account'),
                  ),
                ],
              ),
            )
          else if (items.isEmpty)
            const FunkyCard(child: EmptyNote(text: "Nothing yet. You'll see new messages, friend requests, new verified places near you, and reports at places you're going to."))
          else
            for (final n in items) _NotificationTile(n: n, onTap: () => _open(context, store, n)),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification n;
  final VoidCallback onTap;
  const _NotificationTile({required this.n, required this.onTap});

  IconData get _icon {
    switch (n.kind) {
      case 'dm':
        return Icons.chat_bubble_outline;
      case 'group':
        return Icons.groups_outlined;
      case 'friend':
        return Icons.person_add_alt_1_outlined;
      case 'place':
        return Icons.place_outlined;
      case 'mention':
        return Icons.alternate_email;
      case 'photo':
        return Icons.photo_outlined;
      default:
        return Icons.campaign_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: n.read ? tokens.surface : tokens.brand.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: n.read ? tokens.line : tokens.brand.withValues(alpha: 0.45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle),
                  child: Icon(_icon, size: 20, color: tokens.ink),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.title, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                      if (n.body.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(n.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink)),
                      ],
                      const SizedBox(height: 4),
                      Text(timeAgoLabel(n.createdAt.millisecondsSinceEpoch), style: TextStyle(color: tokens.mute, fontSize: 12)),
                    ],
                  ),
                ),
                if (!n.read)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Container(width: 9, height: 9, decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
