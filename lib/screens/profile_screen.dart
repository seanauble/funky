import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/ui_widgets.dart';
import 'camera_capture_screen.dart';
import 'friend_requests_screen.dart';
import 'memories_screen.dart';
import 'points_info_screen.dart';

enum _PhotoSource { camera, library }

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
                        child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: TextField(
                      controller: _handleController,
                      onSubmitted: (_) => _commitHandle(store),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(hintText: 'Pick a screen name', hintStyle: TextStyle(color: tokens.mute), border: InputBorder.none),
                      style: TextStyle(color: tokens.ink, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _commitHandle(store),
                    tooltip: 'Save username',
                    icon: Icon(Icons.check_circle_outline, color: tokens.brand, size: 20),
                  ),
                  if (store.isVerifiedUser) Icon(Icons.verified, color: tokens.brand, size: 20),
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
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MemoriesScreen())),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Memories', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  Text('›', style: TextStyle(color: tokens.mute)),
                ],
              ),
            ),
          ),
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
