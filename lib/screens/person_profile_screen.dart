import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'dm_thread_screen.dart';
import 'story_viewer_screen.dart';

/// A FUNKY Admin-only confirmation before banning — this severs an existing
/// friendship/pending request and hides the person's Stories/chat/DMs
/// everywhere on this device, so it's worth one tap to make sure before it
/// happens rather than a single accidental tap on the profile.
Future<void> _confirmBan(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.surface,
      title: Text('Ban @$handle?', style: TextStyle(color: tokens.ink)),
      content: Text(
        "This unfriends them if you're friends, and hides their Stories, chat messages, and DMs from everyone on this device.",
        style: TextStyle(color: tokens.mute),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Ban', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (confirmed == true) store.banUser(personId);
}

/// Admin-only: gives (or takes away) points and tells the admin how it went.
Future<void> _giveAdminPoints(BuildContext context, AppStore store, String personId, String handle, int amount) async {
  final error = await store.adminGivePoints(personId, amount);
  if (!context.mounted) return;
  final text = amount > 0 ? 'Gave @$handle +$amount points.' : 'Removed ${-amount} points from @$handle.';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(error ?? text), duration: const Duration(seconds: 1)),
  );
}

/// Admin-only: type any amount and either give or remove that many points.
Future<void> _customAdminPoints(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final controller = TextEditingController();
  final choice = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.surface,
      title: Text('Points for @$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 7,
        decoration: InputDecoration(hintText: 'Amount', hintStyle: TextStyle(color: tokens.mute), counterText: ''),
        style: TextStyle(color: tokens.ink),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text('Cancel', style: TextStyle(color: tokens.mute))),
        TextButton(
          onPressed: () {
            final n = int.tryParse(controller.text.trim()) ?? 0;
            Navigator.of(dialogContext).pop(n > 0 ? -n : null);
          },
          child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
        ),
        TextButton(
          onPressed: () {
            final n = int.tryParse(controller.text.trim()) ?? 0;
            Navigator.of(dialogContext).pop(n > 0 ? n : null);
          },
          child: Text('Give', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  controller.dispose();
  if (choice == null || !context.mounted) return;
  await _giveAdminPoints(context, store, personId, handle, choice);
}

/// Pick a reason, send the report to the FUNKY team.
Future<void> _reportProfile(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Text('Report @$handle', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          for (final r in AppStore.profileReportReasons)
            ListTile(
              title: Text(r, style: TextStyle(color: tokens.ink)),
              onTap: () => Navigator.of(sheetContext).pop(r),
            ),
        ],
        ),
      ),
    ),
  );
  if (reason == null || !context.mounted) return;
  final message = await store.reportProfile(personId, reason);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

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
    final theirStories = canSeeStories ? store.storiesByUser(personId) : const <Story>[];
    final banned = store.isBanned(personId);
    // The story ring around their picture: tonight's Stories (all of a
    // friend's recent ones). Anonymous posts don't count — a ring would give
    // away who posted them.
    final ringStories = store.visibleStoriesByUser(personId).where((s) => !s.anon).toList();
    final hasRing = ringStories.isNotEmpty && !banned;
    final ringUnseen = ringStories.any((s) => !s.views.contains('me'));
    final ringColor = ringUnseen ? (isFriend ? tokens.friend : tokens.orange) : tokens.line;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text('@${person.handle}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Column(
              children: [
                // Tap: their Stories (when they have any), otherwise the big
                // picture. Press and hold: the big picture preview.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: hasRing
                      ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: [personId])))
                      : () => showAvatarPreview(context, person, viewProfile: false),
                  onLongPress: () => showAvatarPreview(context, person, viewProfile: false),
                  child: Container(
                    width: 96,
                    height: 96,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: hasRing ? Border.all(color: ringColor, width: 3) : null,
                    ),
                    child: PersonAvatar(person: person, size: 84, preview: false),
                  ),
                ),
                const SizedBox(height: 10),
                FunkyHandle(handle: person.handle, person: person),
                if (person.bio.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(person.bio, textAlign: TextAlign.center, style: TextStyle(color: tokens.mute)),
                ],
                const SizedBox(height: 4),
                Text('${person.points} pts · Lv ${levelFor(person.points)}', style: TextStyle(color: tokens.mute, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Anyone can message anyone on FUNKY — being friends only gates
          // seeing each other's old Stories (below), not DMs.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: personId))),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: tokens.line),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(Icons.chat_bubble_outline, size: 18, color: tokens.ink),
              label: Text('Message', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
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
          if (personId != 'me' && store.signedIn)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Center(
                child: TextButton.icon(
                  onPressed: () => _reportProfile(context, store, personId, person.handle),
                  icon: Icon(Icons.flag_outlined, size: 16, color: tokens.mute),
                  label: Text('Report this profile', style: TextStyle(color: tokens.mute, fontSize: 13)),
                ),
              ),
            ),
          // Only a signed-in FUNKY Admin ever sees this — same hardcoded-
          // admin gate as the place verification controls on
          // place_detail_screen. Banning severs any friendship/pending
          // request with them and hides their Stories/chat messages/DMs
          // everywhere on this device (see AppStore.banUser).
          if (store.isAdmin && personId != 'me') ...[
            const SizedBox(height: 10),
            // Give points — as many times as you like; each tap is applied
            // on the server and the person's app picks it up live.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final amount in const [100, 500, 1000, -100, -500, -1000])
                  OutlinedButton(
                    onPressed: () => _giveAdminPoints(context, store, personId, person.handle, amount),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: tokens.gold),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      amount > 0 ? '+$amount pts' : '$amount pts',
                      style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _customAdminPoints(context, store, personId, person.handle),
                  icon: Icon(Icons.tune, size: 16, color: tokens.gold),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: tokens.gold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  label: Text('Custom', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => banned ? store.unbanUser(personId) : _confirmBan(context, store, personId, person.handle),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: tokens.danger),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(banned ? Icons.lock_open : Icons.block, size: 18, color: tokens.danger),
                label: Text(
                  banned ? 'Unban user (Admin)' : 'Ban user (Admin)',
                  style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            // Only the owner can hand out (or take back) admin access.
            if (store.isOwner) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final makeAdmin = !person.isAdminUser;
                    final error = await store.adminSetAdmin(personId, makeAdmin);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(error ?? (makeAdmin ? '@${person.handle} is now an admin.' : '@${person.handle} is no longer an admin.')),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: tokens.gold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: Icon(person.isAdminUser ? Icons.shield_outlined : Icons.shield, size: 18, color: tokens.gold),
                  label: Text(
                    person.isAdminUser ? 'Remove admin access' : 'Make admin',
                    style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ],
          const SectionHeader(title: 'Stories'),
          if (canSeeStories)
            if (theirStories.isEmpty)
              const EmptyNote(text: "Nothing posted yet tonight.")
            else
              ...theirStories.map((s) {
                // The viewer plays oldest-first, this list is newest-first.
                final viewerIndex = theirStories.length - 1 - theirStories.indexOf(s);
                final hasVideo = s.videoPath != null || s.videoUrl != null;
                final hasText = s.text != null && s.text!.isNotEmpty;
                // The picture itself (or a frame of the video) — a friend's
                // Story only has a signed URL here; their local file lives
                // on their own phone.
                Widget? media;
                if (hasVideo) {
                  media = VideoFrameThumbnail(path: s.videoPath, url: s.videoPath == null ? s.videoUrl : null);
                } else if (s.imagePath != null && File(s.imagePath!).existsSync()) {
                  media = Image.file(File(s.imagePath!), fit: BoxFit.cover);
                } else if (s.imageUrl != null) {
                  media = Image.network(
                    s.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(color: tokens.raised, alignment: Alignment.center, child: Icon(Icons.broken_image_outlined, color: tokens.mute)),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: [personId], initialStoryIndex: viewerIndex)),
                    ),
                    child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      color: tokens.surface,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (media != null)
                            SizedBox(
                              height: 220,
                              width: double.infinity,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  media,
                                  if (hasVideo)
                                    Center(
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (hasText)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(s.text!, style: TextStyle(color: tokens.ink, fontSize: 15, height: 1.3)),
                                  )
                                else if (media == null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text('Text story', style: TextStyle(color: tokens.mute)),
                                  ),
                                Text(timeAgoLabel(s.t), style: TextStyle(color: tokens.mute, fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ),
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
