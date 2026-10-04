import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/ui_widgets.dart';
import 'camera_capture_screen.dart';
import 'friend_requests_screen.dart';
import 'points_info_screen.dart';
import 'story_viewer_screen.dart';

enum _PhotoSource { camera, library }

const _memoryMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _memoryDayLabel(DateTime dt) => '${_memoryMonths[dt.month - 1]} ${dt.day}, ${dt.year}';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _handleController;
  late TextEditingController _bioController;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _handleController = TextEditingController(text: store.me.handle);
    _bioController = TextEditingController(text: store.me.bio);
  }

  @override
  void dispose() {
    _handleController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  /// Picks a new profile photo — either the in-app camera (same as before)
  /// or an existing photo from the library. Stories stay camera-only; this
  /// is the one place in the app that opens an actual gallery picker.
  Future<void> _changePhoto(AppStore store) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final source = await showModalBottomSheet<_PhotoSource>(
      context: context,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => const _PhotoSourceSheet(),
    );
    if (source == null || !mounted) return;

    if (source == _PhotoSource.camera) {
      await _changePhotoFromCamera(store);
    } else {
      await _changePhotoFromLibrary(store);
    }
  }

  Future<void> _changePhotoFromCamera(AppStore store) async {
    final media = await Navigator.of(context).push<CapturedMedia>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraCaptureScreen()),
    );
    if (media == null || !mounted) return;
    if (media.isVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile pictures are photos only — tap the shutter instead of holding it.')),
      );
      return;
    }
    store.setProfilePhoto(media.file.path);
  }

  Future<void> _changePhotoFromLibrary(AppStore store) async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (picked == null || !mounted) return;
      // Copy into our own app-documents folder, same as every camera
      // capture already does — the picker's own temp file isn't guaranteed
      // to stick around.
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/stories');
      if (!await dir.exists()) await dir.create(recursive: true);
      final dest = '${dir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = await File(picked.path).copy(dest);
      if (!mounted) return;
      store.setProfilePhoto(savedFile.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that photo: $e')));
      }
    }
  }

  /// Commits whatever's in the handle field right now — called on submit
  /// (keyboard "done") or the save button, not on every keystroke like
  /// before, since every keystroke used to try to spend the 15-day cooldown.
  void _commitHandle(AppStore store) {
    final error = store.setHandle(_handleController.text);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      setState(() => _handleController.text = store.me.handle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    final friends = store.me.friends.length;
    final title = store.myLevelTitle;
    final badges = store.myBadges;

    // Grouped by calendar day, same as the old standalone Memories screen —
    // now rendered straight on the profile page itself instead of behind a
    // tap-through link.
    final myStories = store.myStories; // newest first already
    final memoriesByDay = <String, List<Story>>{};
    for (final s in myStories) {
      final key = _memoryDayLabel(DateTime.fromMillisecondsSinceEpoch(s.t));
      (memoriesByDay[key] ??= []).add(s);
    }

    // No AppBar of its own anymore — the root shell's shared AppBar now
    // carries the title, notification bell, and settings gear on every
    // tab, not just this one.
    return Scaffold(
      backgroundColor: tokens.bg,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          Column(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  FunkyAvatar(
                    seed: store.me.id,
                    label: store.me.handle.isNotEmpty ? store.me.handle : '?',
                    size: 88,
                    photoPath: store.me.photoPath,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: GestureDetector(
                      onTap: () => _changePhoto(store),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle, border: Border.all(color: tokens.bg, width: 2.5)),
                        // A pencil, not a camera — tapping this opens "take a
                        // new photo or choose from library" to change the
                        // profile picture, not a camera/Story capture, and a
                        // camera icon here read as if it did the latter.
                        child: const Icon(Icons.edit, color: Colors.white, size: 15),
                      ),
                    ),
                  ),
                ],
              ),
              // A plain Row(mainAxisSize: min) here used to center the
              // *whole row* — text plus the save icon (plus the verified
              // badge, when present) — as one block. Since those icons only
              // sit on the right, that block's true center sat left of the
              // text field's own center, so the username itself always
              // looked off-center. Stacking them instead lets the text
              // field span (and center within) the full width on its own,
              // with the icons floating on top at the right edge instead of
              // pushing the text off-balance.
              Stack(
                alignment: Alignment.center,
                children: [
                  TextField(
                    controller: _handleController,
                    onSubmitted: (_) => _commitHandle(store),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: 'Pick a screen name',
                      hintStyle: TextStyle(color: tokens.mute),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 52),
                    ),
                    style: TextStyle(color: tokens.ink, fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  Positioned(
                    right: 0,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _commitHandle(store),
                          tooltip: 'Save username',
                          icon: Icon(Icons.check_circle_outline, color: tokens.brand, size: 20),
                        ),
                        if (store.isVerifiedUser) Icon(Icons.verified, color: tokens.brand, size: 20),
                      ],
                    ),
                  ),
                ],
              ),
              Text(
                'Usernames can only change once every 15 days.',
                style: TextStyle(color: tokens.mute, fontSize: 11),
              ),
              TextField(
                controller: _bioController,
                onChanged: store.setBio,
                textAlign: TextAlign.center,
                decoration: InputDecoration(hintText: 'Add a bio', hintStyle: TextStyle(color: tokens.mute), border: InputBorder.none),
                style: TextStyle(color: tokens.mute, fontSize: 14),
              ),
              if (title != null) ...[
                const SizedBox(height: 4),
                Text('${title.emoji} ${title.title}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
              ],
              if (badges.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: badges
                      .map((b) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(999)),
                            child: Text('${b.emoji} ${b.label}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12)),
                          ))
                      .toList(),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(
                label: 'Funky Points · Lv ${store.level}',
                value: store.me.points,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointsInfoScreen())),
              ),
              _Stat(
                label: 'Friends',
                value: friends,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen())),
              ),
            ],
          ),
          const SectionHeader(title: 'Memories'),
          if (myStories.isEmpty)
            const FunkyCard(
              child: EmptyNote(
                text: "Nothing saved yet. Post a Story and it'll show up here for $memoryRetentionDays days — tap the bookmark on "
                    "one to keep it on your Timeline forever.",
              ),
            )
          else
            ...memoriesByDay.entries.expand((entry) => <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Text(entry.key, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                  ),
                  ...entry.value.map((s) {
                    // myStories is newest-first; the Story viewer always
                    // plays oldest-first, so this story's position there is
                    // counted back from the end rather than reusing its
                    // position here directly.
                    final viewerIndex = myStories.length - 1 - myStories.indexOf(s);
                    return _ProfileMemoryCard(
                      story: s,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: const ['me'], initialStoryIndex: viewerIndex)),
                      ),
                    );
                  }),
                ]),
          const SectionHeader(title: 'Privacy'),
          FunkyCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Anonymous mode', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Hides your name and profile on chat and Stories.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ],
                  ),
                ),
                Switch(value: store.me.anon, onChanged: store.setAnon, activeTrackColor: tokens.brand),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom sheet that asks "take a new photo or pick one from your
/// library" when you tap the camera badge on your profile picture.
class _PhotoSourceSheet extends StatelessWidget {
  const _PhotoSourceSheet();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 4, decoration: BoxDecoration(color: tokens.line, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.camera_alt, color: tokens.ink),
            title: Text('Take Photo', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.of(context).pop(_PhotoSource.camera),
          ),
          ListTile(
            leading: Icon(Icons.photo_library_outlined, color: tokens.ink),
            title: Text('Choose from Library', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.of(context).pop(_PhotoSource.library),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Same card as the old standalone Memories screen used — duplicated here
/// (rather than imported) since memories now render directly on this page.
/// Tapping it opens the full Story viewer at exactly this memory; the trash
/// icon deletes it right here without having to go in first.
class _ProfileMemoryCard extends StatelessWidget {
  final Story story;
  final VoidCallback onTap;
  const _ProfileMemoryCard({required this.story, required this.onTap});

  Future<void> _confirmDelete(BuildContext context) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text('Delete this memory?', style: TextStyle(color: tokens.ink)),
        content: Text('This removes it for good — it can\'t be undone.', style: TextStyle(color: tokens.mute)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('Cancel', style: TextStyle(color: tokens.mute))),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text('Delete', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<AppStore>().deleteStory(story.id);
    }
  }

  void _toggleTimeline(BuildContext context) {
    final store = context.read<AppStore>();
    if (story.savedToTimeline) {
      store.removeFromTimeline(story.id);
    } else {
      store.saveToTimeline(story.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final dt = DateTime.fromMillisecondsSinceEpoch(story.t);
    final timeLabel = TimeOfDay.fromDateTime(dt).format(context);
    final daysLeft = memoryDaysLeft(story);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.place, size: 13, color: tokens.mute),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  story.placeName ?? 'Area-wide',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Text(timeLabel, style: TextStyle(color: tokens.mute, fontSize: 12)),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleTimeline(context),
                child: Icon(
                  story.savedToTimeline ? Icons.bookmark : Icons.bookmark_outline,
                  size: 16,
                  color: story.savedToTimeline ? tokens.brand : tokens.mute,
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmDelete(context),
                child: Icon(Icons.delete_outline, size: 16, color: tokens.mute),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Every Memory counts down to auto-delete unless it's been pinned
          // to the Timeline — see AppStore._purgeExpiredMemories.
          Row(
            children: [
              Icon(
                story.savedToTimeline ? Icons.bookmark : Icons.schedule,
                size: 12,
                color: story.savedToTimeline ? tokens.brand : tokens.mute,
              ),
              const SizedBox(width: 4),
              Text(
                story.savedToTimeline
                    ? 'Saved to Timeline'
                    : (daysLeft <= 0 ? 'Expires today' : 'Expires in $daysLeft day${daysLeft == 1 ? '' : 's'}'),
                style: TextStyle(
                  color: story.savedToTimeline ? tokens.brand : tokens.mute,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (story.videoPath != null || story.videoUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                alignment: Alignment.bottomLeft,
                children: [
                  Container(height: 140, width: double.infinity, color: Colors.black),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam, color: Colors.white, size: 16),
                        const SizedBox(width: 4),
                        const Text('Video Story', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else if (story.imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(File(story.imagePath!), height: 140, width: double.infinity, fit: BoxFit.cover),
            )
          // A Memory synced from another device you posted it on has no
          // local file here — only the signed URL fetched from the real
          // backend (see Story.imageUrl's doc comment in models.dart).
          else if (story.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(story.imageUrl!, height: 140, width: double.infinity, fit: BoxFit.cover),
            ),
          if (story.videoPath != null || story.imagePath != null || story.videoUrl != null || story.imageUrl != null)
            const SizedBox(height: 8),
          if (story.text != null && story.text!.isNotEmpty)
            Text(story.text!, style: TextStyle(color: tokens.ink))
          else if (story.videoPath == null && story.imagePath == null && story.videoUrl == null && story.imageUrl == null)
            Text('Text story', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.remove_red_eye_outlined, size: 14, color: tokens.mute),
              const SizedBox(width: 4),
              Text('${story.views.length} view${story.views.length == 1 ? '' : 's'}', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
              if (story.screenshotBy.isNotEmpty) ...[
                const SizedBox(width: 14),
                Icon(Icons.camera_alt_outlined, size: 14, color: tokens.orange),
                const SizedBox(width: 4),
                Text(
                  '${story.screenshotBy.length} screenshotted',
                  style: TextStyle(color: tokens.orange, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        ],
      ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback? onTap;
  const _Stat({required this.label, required this.value, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Text('$value', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 20)),
            Text(label, style: TextStyle(color: tokens.mute, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
