import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/ui_widgets.dart';
import 'add_friends_screen.dart';
import 'person_profile_screen.dart';

/// Opened from the bell icon (and the "Friends" stat) on Profile. Shows your
/// actual current friends with their @handles up top, then incoming
/// requests needing your accept/decline, then outgoing ones shown as
/// pending with a way to cancel them if you change your mind.
class FriendRequestsScreen extends StatelessWidget {
  const FriendRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final friends = store.myFriends;
    final incoming = store.incomingFriendRequests;
    final outgoing = store.outgoingFriendRequests;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: const Text('Friends'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddFriendsScreen())),
            icon: const Icon(Icons.search),
            tooltip: 'Add friends by username',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionHeader(title: 'Friends · ${friends.length}'),
          if (friends.isEmpty)
            const EmptyNote(text: "You haven't added any friends yet.")
          else
            ...friends.map((p) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                        child: FunkyAvatar(seed: p.id, label: p.handle.isNotEmpty ? p.handle : '?', size: 40, photoPath: p.photoPath),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                          child: FunkyHandle(handle: p.handle, person: p),
                        ),
                      ),
                      IconButton(
                        onPressed: () => store.removeFriend(p.id),
                        icon: Icon(Icons.person_remove_outlined, color: tokens.mute),
                        tooltip: 'Remove friend',
                      ),
                    ],
                  ),
                )),
          const SectionHeader(title: 'Requests'),
          if (incoming.isEmpty)
            const EmptyNote(text: 'No pending friend requests right now.')
          else
            ...incoming.map((p) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                        child: FunkyAvatar(seed: p.id, label: p.handle.isNotEmpty ? p.handle : '?', size: 40, photoPath: p.photoPath),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                          child: FunkyHandle(handle: p.handle),
                        ),
                      ),
                      IconButton(
                        onPressed: () => store.acceptFriendRequest(p.id),
                        icon: Icon(Icons.check_circle, color: tokens.brand),
                      ),
                      IconButton(
                        onPressed: () => store.declineFriendRequest(p.id),
                        icon: Icon(Icons.cancel, color: tokens.mute),
                      ),
                    ],
                  ),
                )),
          const SectionHeader(title: 'Sent'),
          if (outgoing.isEmpty)
            const EmptyNote(text: "You haven't sent any friend requests.")
          else
            ...outgoing.map((p) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                        child: FunkyAvatar(seed: p.id, label: p.handle.isNotEmpty ? p.handle : '?', size: 40, photoPath: p.photoPath),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
                          child: FunkyHandle(handle: p.handle),
                        ),
                      ),
                      Text('Pending', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                      IconButton(
                        onPressed: () => store.cancelFriendRequest(p.id),
                        icon: Icon(Icons.close, color: tokens.mute),
                        tooltip: 'Cancel request',
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}
