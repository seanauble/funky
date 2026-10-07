import 'package:flutter/material.dart';
import 'data/app_store.dart';
import 'root_shell.dart';
import 'screens/dm_thread_screen.dart';
import 'screens/friend_requests_screen.dart';
import 'screens/group_thread_screen.dart';
import 'screens/place_detail_screen.dart';

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
      final placeId = data['place_id'];
      if (placeId is! String) return;
      navigator.popUntil((r) => r.isFirst);
      navigator.push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
  }
}
