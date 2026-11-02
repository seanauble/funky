import 'package:flutter/material.dart';
import 'data/app_store.dart';
import 'root_shell.dart';
import 'screens/admin_panel_screen.dart';
import 'screens/call_screen.dart';
import 'screens/dm_thread_screen.dart';
import 'screens/event_chat_screen.dart';
import 'screens/poll_comments_screen.dart';
import 'screens/friend_requests_screen.dart';
import 'screens/group_thread_screen.dart';
import 'screens/place_detail_screen.dart';
import 'screens/posts_screen.dart';
import 'screens/referral_screen.dart';
import 'screens/event_manage_screen.dart';

/// Lets code outside the widget tree (a tapped push notification) push
/// screens.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Where a tapped push notification should land: a DM opens that
/// conversation, a friend request opens the requests list, a place/report
/// opens the place, an @mention opens the Chat tab.
Future<void> openPushTarget(AppStore store, String kind, Map<String, dynamic> data) async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  switch (kind) {
    case 'dm':
      final from = data['from'];
      if (from is! String) return;
      await store.ensurePerson(from);
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
    case 'call':
      final from = data['from'];
      if (from is! String) return;
      await store.ensurePerson(from);
      final callId = data['call_id'];
      // A ring that's still going opens the answer screen (unless it's
      // already up); a missed call just opens the conversation.
      if (callId is String) {
        if (store.incomingCall?.id == callId) return;
        final call = await store.fetchCall(callId);
        if (call != null && call.status == 'ringing' && DateTime.now().difference(call.createdAt) < const Duration(seconds: 55)) {
          navigator.push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => IncomingCallScreen(callId: callId, fromId: from),
          ));
          return;
        }
      }
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
    case 'group_call':
    case 'group':
      final groupId = data['group_id'];
      if (groupId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => GroupThreadScreen(groupId: groupId)));
    case 'friend':
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen()));
    case 'mention':
      navigator.popUntil((r) => r.isFirst);
      rootShellTabRequest.value = 1;
    case 'place':
    case 'report':
    case 'photo':
    case 'friends_going':
    case 'invite':
    case 'claim':
    case 'reward_used':
    case 'event_role':
      final placeId = data['place_id'];
      if (placeId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
    case 'event_chat':
      final placeId = data['place_id'];
      if (placeId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => EventChatScreen(placeId: placeId)));
    case 'poll_comment':
      final pollId = data['poll_id'];
      if (pollId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => PollCommentsScreen(pollId: pollId)));
    case 'post_comment':
    case 'post_like':
    case 'friend_post':
    case 'post_award':
      final postId = data['post_id'];
      if (postId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: postId)));
    case 'referral':
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => const ReferralScreen()));
    case 'event_request':
      final placeId = data['place_id'];
      if (placeId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      final ev = store.places.where((x) => x.id == placeId).firstOrNull;
      navigator.push(MaterialPageRoute(
        builder: (_) => ev != null && store.canManageEvent(ev) ? EventManageScreen(placeId: placeId) : PlaceDetailScreen(placeId: placeId),
      ));
    case 'pay':
      final from = data['from'];
      final groupId = data['group_id'];
      final placeId = data['place_id'];
      navigator.popUntil((r) => r.isFirst);
      if (from is String) {
        await store.ensurePerson(from);
        navigator.push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: from)));
      } else if (groupId is String) {
        navigator.push(MaterialPageRoute(builder: (_) => GroupThreadScreen(groupId: groupId)));
      } else if (placeId is String) {
        navigator.push(MaterialPageRoute(builder: (_) => EventChatScreen(placeId: placeId)));
      }
    case 'story_report':
    case 'claim_request':
      if (!store.isAdmin) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
  }
}
