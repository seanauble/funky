import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/notification_models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ios_ui.dart';
import '../widgets/ui_widgets.dart';
import '../root_shell.dart';
import 'account_screen.dart';
import 'admin_panel_screen.dart';
import 'dm_thread_screen.dart';
import 'event_chat_screen.dart';
import 'poll_comments_screen.dart';
import 'friend_requests_screen.dart';
import 'group_thread_screen.dart';
import 'place_detail_screen.dart';
import 'posts_screen.dart';

/// Opened from the bell: friend requests up top, then everything that
/// happened — Today and Earlier — as cards with who did it, what happened
/// and a preview. Several of the same thing from the same person ("3 new
/// replies") are folded into one card. All / Unread tabs; swipe a card
/// away to remove it; ··· to mark all read or clear everything.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().ensureNotificationPeople();
    });
  }

  Future<void> _open(BuildContext context, AppStore store, List<AppNotification> group) async {
    final navigator = Navigator.of(context);
    final n = group.first;
    for (final x in group) {
      unawaited(store.markNotificationRead(x.id));
    }
    switch (n.kind) {
      case 'dm':
        final from = n.data['from'] as String?;
        if (from == null) return;
        await store.ensurePerson(from);
        navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
      case 'call':
        final from = n.data['from'] as String?;
        if (from == null) return;
        await store.ensurePerson(from);
        navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
      case 'group_call':
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
      case 'friends_going':
      case 'invite':
        final placeId = n.data['place_id'] as String?;
        if (placeId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
      case 'event_chat':
        final placeId = n.data['place_id'] as String?;
        if (placeId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => EventChatScreen(placeId: placeId)));
      case 'poll_comment':
        final pollId = n.data['poll_id'] as String?;
        if (pollId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => PollCommentsScreen(pollId: pollId)));
      case 'post_comment':
      case 'post_like':
      case 'friend_post':
      case 'post_award':
        final postId = n.data['post_id'] as String?;
        if (postId == null) return;
        navigator.push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: postId)));
      case 'story_report':
        if (!store.isAdmin) return;
        navigator.push(MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
    }
  }

  Future<void> _more(AppStore store) async {
    final choice = await showIosActionSheet<String>(
      context,
      actions: [
        if (store.unreadNotificationCount > 0) const IosSheetAction('Mark all as read', 'read', icon: Icons.done_all_rounded),
        const IosSheetAction('Clear all notifications', 'clear', destructive: true, icon: Icons.delete_outline_rounded),
      ],
    );
    if (!mounted) return;
    if (choice == 'read') {
      await store.markAllNotificationsRead();
      return;
    }
    if (choice == 'clear') {
      final ok = await showIosDialog<bool>(
        context: context,
        builder: (ctx) => IosAlert(
          title: const Text('Clear all notifications?'),
          content: const Text("They'll be gone from here for good."),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Clear all')),
          ],
        ),
      );
      if (ok == true) await store.clearAllNotifications();
    }
  }

  // Notifications that can stack into one card, and what to call several.
  static const _stackNouns = {
    'dm': 'messages',
    'mention': 'replies',
    'post_comment': 'comments',
    'post_like': 'likes',
    'group': 'messages',
    'event_chat': 'messages',
    'poll_comment': 'comments',
  };

  static String _stackKey(AppNotification n) {
    final d = n.data;
    final target = d['post_id'] ?? d['place_id'] ?? d['group_id'] ?? d['poll_id'] ?? (d['chat'] == true ? 'chat' : '');
    return '${n.kind}|${d['from'] ?? ''}|$target';
  }

  /// Newest first, with stackable ones folded together.
  static List<List<AppNotification>> _group(List<AppNotification> items) {
    final out = <List<AppNotification>>[];
    final byKey = <String, List<AppNotification>>{};
    for (final n in items) {
      if (_stackNouns.containsKey(n.kind)) {
        final key = _stackKey(n);
        final existing = byKey[key];
        if (existing != null) {
          existing.add(n);
          continue;
        }
        final g = [n];
        byKey[key] = g;
        out.add(g);
      } else {
        out.add([n]);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final all = store.notifications;
    final unread = store.unreadNotificationCount;
    final items = _unreadOnly ? all.where((n) => !n.read).toList() : all;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayItems = _group(items.where((n) => !n.createdAt.isBefore(today)).toList());
    final earlierItems = _group(items.where((n) => n.createdAt.isBefore(today)).toList());

    Widget sectionHeader(String title, {bool withMarkAll = false}) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
          child: Row(
            children: [
              Expanded(child: Text(title, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 20))),
              if (withMarkAll && unread > 0)
                GestureDetector(
                  onTap: store.markAllNotificationsRead,
                  child: Text('Mark all read', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700, fontSize: 15)),
                ),
            ],
          ),
        );

    Widget card(List<AppNotification> g) => _NotificationCard(
          key: ValueKey(g.first.id),
          group: g,
          noun: _stackNouns[g.first.kind],
          onTap: () => _open(context, store, g),
          onDismiss: () => store.deleteNotifications([for (final n in g) n.id]),
        );

    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Back, the big title, and ···
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 6, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.chevron_left_rounded, color: tokens.ink, size: 34),
                  ),
                  Expanded(
                    child: Text('Notifications', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 30, letterSpacing: -0.6)),
                  ),
                  if (store.signedIn && all.isNotEmpty)
                    IconButton(
                      tooltip: 'More',
                      onPressed: () => _more(store),
                      icon: Icon(Icons.more_horiz_rounded, color: tokens.ink, size: 28),
                    ),
                ],
              ),
            ),
            // All · Unread
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  _Tab(label: 'All', active: !_unreadOnly, onTap: () => setState(() => _unreadOnly = false)),
                  const SizedBox(width: 30),
                  _Tab(label: unread > 0 ? 'Unread  $unread' : 'Unread', active: _unreadOnly, onTap: () => setState(() => _unreadOnly = true)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
                children: [
                  _FriendRequestsCard(store: store),
                  if (!store.signedIn) ...[
                    const SizedBox(height: 14),
                    _SignedOutCard(),
                  ] else if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 60),
                      child: Column(
                        children: [
                          Icon(_unreadOnly ? Icons.done_all_rounded : Icons.notifications_none_rounded, color: tokens.mute, size: 44),
                          const SizedBox(height: 10),
                          Text(
                            _unreadOnly ? "You're all caught up." : 'Nothing yet.',
                            style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _unreadOnly ? 'New stuff shows up here first.' : 'Messages, replies, likes, invites and friend requests show up here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: tokens.mute, fontSize: 14),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    if (todayItems.isNotEmpty) ...[
                      sectionHeader('Today', withMarkAll: true),
                      for (final g in todayItems) card(g),
                    ],
                    if (earlierItems.isNotEmpty) ...[
                      sectionHeader('Earlier', withMarkAll: todayItems.isEmpty),
                      for (final g in earlierItems) card(g),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: TextStyle(color: active ? tokens.brand : tokens.mute, fontWeight: active ? FontWeight.w800 : FontWeight.w600, fontSize: 19),
              child: Text(label),
            ),
          ),
          Positioned(
            left: -6,
            right: -6,
            bottom: 0,
            height: 3.5,
            child: AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: DecoratedBox(decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(3))),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Friend requests · 2 waiting" with the first two faces.
class _FriendRequestsCard extends StatelessWidget {
  final AppStore store;
  const _FriendRequestsCard({required this.store});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final pending = store.pendingFriendRequestCount;
    final faces = store.incomingFriendRequests.take(2).toList();
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: tokens.line.withValues(alpha: 0.8))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen())),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(
            children: [
              if (faces.isEmpty)
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(Icons.people_alt_rounded, color: tokens.brand, size: 24),
                )
              else
                SizedBox(
                  width: 48.0 + (faces.length - 1) * 30,
                  height: 48,
                  child: Stack(
                    children: [
                      for (var i = faces.length - 1; i >= 0; i--)
                        Positioned(
                          left: 30.0 * i,
                          child: Container(
                            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.surface, width: 2.5)),
                            child: PersonAvatar(person: faces[i], size: 44, preview: false),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Friend requests', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16.5)),
                    const SizedBox(height: 2),
                    Text(
                      pending == 0 ? 'None waiting · see your friends' : '$pending waiting',
                      style: TextStyle(color: pending == 0 ? tokens.mute : tokens.brand, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: tokens.mute, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedOutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: tokens.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Make an account to get notifications', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          Text("Messages, replies, friend requests, invites, and updates at the places you're going to.", style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Make an account', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

/// One notification (or a stack of the same kind from the same person):
/// their picture with a small badge for what it is, @who, what happened,
/// a preview, how long ago and a dot while it's unread.
class _NotificationCard extends StatelessWidget {
  final List<AppNotification> group;
  final String? noun;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const _NotificationCard({super.key, required this.group, required this.noun, required this.onTap, required this.onDismiss});

  static IconData iconFor(String kind) {
    switch (kind) {
      case 'dm':
        return Icons.chat_bubble_outline_rounded;
      case 'call':
      case 'group_call':
        return Icons.videocam_outlined;
      case 'group':
        return Icons.groups_outlined;
      case 'friend':
        return Icons.person_add_alt_1_outlined;
      case 'place':
        return Icons.place_outlined;
      case 'report':
        return Icons.campaign_outlined;
      case 'mention':
        return Icons.chat_bubble_outline_rounded;
      case 'photo':
        return Icons.photo_outlined;
      case 'story_report':
        return Icons.flag_outlined;
      case 'post_comment':
        return Icons.mode_comment_outlined;
      case 'event_chat':
        return Icons.forum_outlined;
      case 'invite':
        return Icons.mail_outline_rounded;
      case 'poll_comment':
        return Icons.poll_outlined;
      case 'post_like':
        return Icons.favorite_border_rounded;
      case 'friend_post':
        return Icons.photo_library_outlined;
      case 'friends_going':
        return Icons.groups_outlined;
      case 'post_award':
        return Icons.emoji_events_outlined;
      case 'moderation':
        return Icons.shield_outlined;
      default:
        return Icons.notifications_none_rounded;
    }
  }

  static String _defaultAction(String kind) => switch (kind) {
        'dm' => 'Sent you a message',
        'call' => 'Called you',
        'friend' => 'Sent you a friend request',
        'post_like' => 'Liked your post',
        _ => '',
      };

  /// "4h", "12m", "3d", or the date.
  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final n = group.first;
    final unread = group.any((x) => !x.read);
    final from = n.data['from'];
    final person = from is String ? store.personById(from) : null;
    final handle = person?.handle;

    var headline = n.title;
    var action = '';
    if (handle != null) {
      headline = '@$handle';
      var rest = n.title.trim();
      if (rest.toLowerCase().startsWith('@${handle.toLowerCase()}')) rest = rest.substring(handle.length + 1).trim();
      if (rest == headline || rest.isEmpty) rest = _defaultAction(n.kind);
      action = rest.isEmpty ? '' : rest[0].toUpperCase() + rest.substring(1);
    }
    if (group.length > 1 && noun != null) {
      final unreadCount = group.where((x) => !x.read).length;
      action = unreadCount > 0 ? '$unreadCount new $noun' : '${group.length} $noun';
    }
    final preview = n.body.trim();

    final badge = Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle, border: Border.all(color: tokens.surface, width: 2)),
      child: Icon(iconFor(n.kind), size: 12.5, color: tokens.ink),
    );
    final avatar = person != null
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              PersonAvatar(person: person, size: 52, preview: false),
              Positioned(right: -3, bottom: -3, child: badge),
            ],
          )
        : Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(iconFor(n.kind), color: tokens.brand, size: 25),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Dismissible(
        key: ValueKey('dismiss_${n.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDismiss(),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          decoration: BoxDecoration(color: tokens.danger, borderRadius: BorderRadius.circular(18)),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
        child: Material(
          color: tokens.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: tokens.line.withValues(alpha: 0.8))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                headline,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(_ago(n.createdAt), style: TextStyle(color: tokens.mute, fontSize: 13.5, fontWeight: FontWeight.w600)),
                            if (unread) ...[
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Container(width: 9, height: 9, decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle)),
                              ),
                            ],
                          ],
                        ),
                        if (action.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(action, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 14.5)),
                        ],
                        if (preview.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 14)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
