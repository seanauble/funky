import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/ui_widgets.dart';

/// The public profile of someone else — reached by tapping their handle in
/// chat. Old Story posts only show up here once you're mutual friends;
/// otherwise it's a locked card with an Add Friend button.
class PersonProfileScreen extends StatelessWidget {
  final String personId;
  const PersonProfileScreen({super.key, required this.personId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(personId);

    if (person == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This person isn't around anymore tonight.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final isFriend = store.isFriendsWith(personId);
    final requestSent = store.hasSentRequestTo(personId);
    final requestReceived = store.hasRequestFrom(personId);
    final canSeeStories = store.canSeeStoriesOf(personId);
    final theirStories = canSeeStories ? store.storiesByUser(personId) : const [];

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text('@${person.handle}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Column(
              children: [
                FunkyAvatar(seed: person.id, label: person.handle.isNotEmpty ? person.handle : '?', size: 84, photoPath: person.photoPath),
                const SizedBox(height: 10),
                FunkyHandle(handle: person.handle, person: person),
                if (person.bio.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(person.bio, textAlign: TextAlign.center, style: TextStyle(color: tokens.mute)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          _FriendAction(
            isFriend: isFriend,
            requestSent: requestSent,
            requestReceived: requestReceived,
            onAdd: () => store.sendFriendRequest(personId),
            onCancel: () => store.cancelFriendRequest(personId),
            onAccept: () => store.acceptFriendRequest(personId),
            onDecline: () => store.declineFriendRequest(personId),
            onRemove: () => store.removeFriend(personId),
          ),
          const SectionHeader(title: 'Stories'),
          if (canSeeStories)
            if (theirStories.isEmpty)
              const EmptyNote(text: "Nothing posted yet tonight.")
            else
              ...theirStories.map((s) {
                final dt = DateTime.fromMillisecondsSinceEpoch(s.t);
                return FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dt.toString(), style: TextStyle(color: tokens.mute, fontSize: 12)),
                      const SizedBox(height: 4),
                      if (s.text != null && s.text!.isNotEmpty)
                        Text(s.text!, style: TextStyle(color: tokens.ink))
                      else if (s.videoPath != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.videocam, size: 16, color: tokens.mute),
                            const SizedBox(width: 4),
                            Text('Video story', style: TextStyle(color: tokens.mute)),
                          ],
                        )
                      else
                        Text('Photo story', style: TextStyle(color: tokens.mute)),
                    ],
                  ),
                );
              })
          else
            FunkyCard(
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: tokens.mute, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Only friends can see @${person.handle}'s Stories.",
                      style: TextStyle(color: tokens.mute, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FriendAction extends StatelessWidget {
  final bool isFriend;
  final bool requestSent;
  final bool requestReceived;
  final VoidCallback onAdd;
  final VoidCallback onCancel;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onRemove;

  const _FriendAction({
    required this.isFriend,
    required this.requestSent,
    required this.requestReceived,
    required this.onAdd,
    required this.onCancel,
    required this.onAccept,
    required this.onDecline,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;

    if (isFriend) {
      return Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Text('Friends ✓', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onRemove,
            child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }

    if (requestReceived) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton(
              onPressed: onAccept,
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('Accept Friend Request', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onDecline,
            child: Text('Decline', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }

    if (requestSent) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onCancel,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            side: BorderSide(color: tokens.line),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text('Request Sent · Cancel', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700)),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onAdd,
        style: ElevatedButton.styleFrom(
          backgroundColor: tokens.brand,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text('Add Friend', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
