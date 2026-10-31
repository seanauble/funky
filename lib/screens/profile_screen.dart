import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'admin_manage_user_screen.dart';
import 'camera_capture_screen.dart';
import 'create_sheet.dart';
import 'friend_requests_screen.dart';
import 'points_info_screen.dart';
import 'profile_parts.dart';
import '../services/share_links.dart';

enum _PhotoSource { camera, library }

/// Your own profile tab: picture, name, bio and title up top, Edit / Share,
/// your numbers, the places you've posted from, and your Memories by month.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // One key per month header, so the calendar button can jump to a month.
  final Map<String, GlobalKey> _monthKeys = {};

  Future<void> _confirmDelete(Story story) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text('Delete this memory?', style: TextStyle(color: tokens.ink)),
        content: Text("This removes it for good — it can't be undone.", style: TextStyle(color: tokens.mute)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('Cancel', style: TextStyle(color: tokens.mute))),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Delete', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) context.read<AppStore>().deleteStory(story.id);
  }

  Future<void> _pickMonth(List<String> months) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                child: Text('Jump to', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              for (final m in months)
                ListTile(
                  title: Text(m, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.of(sheetContext).pop(m),
                ),
            ],
          ),
        ),
      ),
    );
    final ctx = chosen == null ? null : _monthKeys[chosen]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    // Not logged in: there's no profile yet, so don't show a made-up name.
    if (!store.signedIn) return const _SignedOutProfile();

    final me = store.me;
    final title = store.myLevelTitle;
    final badges = store.myBadges;
    final myStories = store.myStories; // newest first
    final places = memoryPlacesFrom(myStories, store);

    // Memories by month, newest month first.
    final byMonth = <String, List<Story>>{};
    for (final s in myStories) {
      (byMonth[monthLabel(DateTime.fromMillisecondsSinceEpoch(s.t))] ??= []).add(s);
    }
    final months = byMonth.keys.toList();
    if (months.isEmpty) months.add(monthLabel(DateTime.now()));
    for (final m in months) {
      _monthKeys.putIfAbsent(m, () => GlobalKey());
    }

    Widget memoryGrid(List<Story> stories, {required bool withAdd}) {
      final count = stories.length + (withAdd ? 1 : 0);
      return GridView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.8,
        ),
        itemCount: count,
        itemBuilder: (context, i) {
          if (i == stories.length) return AddMemoryTile(onTap: () => showCreateSheet(context));
          final s = stories[i];
          return MemoryTile(
            story: s,
            onTap: () => openMemory(context, store, 'me', s),
            onLongPress: () => _confirmDelete(s),
            showBookmark: true,
            onBookmark: () => s.savedToTimeline ? store.removeFromTimeline(s.id) : store.saveToTimeline(s.id),
          );
        },
      );
    }

    final buttonStyle = OutlinedButton.styleFrom(
      backgroundColor: tokens.surface,
      padding: const EdgeInsets.symmetric(vertical: 9),
      minimumSize: const Size(0, 38),
      side: BorderSide(color: tokens.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

    // No AppBar of its own — the root shell's shared AppBar carries the
    // title, notification bell, and settings gear.
    return Scaffold(
      backgroundColor: tokens.bg,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
        children: [
          // Picture on the left; name, bio and title on the right.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.line, width: 2)),
                child: PersonAvatar(person: me, size: 82, viewProfile: false),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StyledName(
                      person: me,
                      text: '@${me.handle}',
                      style: TextStyle(color: tokens.ink, fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    if (me.bio.isNotEmpty)
                      Text(me.bio, style: TextStyle(color: tokens.mute, fontSize: 13.5, height: 1.3))
                    else
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                        child: Text('Add a bio', style: TextStyle(color: tokens.mute.withValues(alpha: 0.7), fontSize: 13.5)),
                      ),
                    if (title != null) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointsInfoScreen())),
                        child: ProfileTitleChip(title: title),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
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
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                  style: buttonStyle,
                  child: Text('Edit profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (buttonContext) => OutlinedButton(
                    onPressed: () => shareFunkyProfile(buttonContext, me.handle, mine: true),
                    style: buttonStyle,
                    child: Text('Share profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ProfileStatsRow(stats: [
            (formatCount(me.points), 'Funky points', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointsInfoScreen()))),
            (formatCount(store.level), 'Level', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointsInfoScreen()))),
            (formatCount(me.friends.length), 'Friends', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendRequestsScreen()))),
          ]),
          // Admin controls live on their own screen, not on the profile.
          if (store.isAdmin)
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminManageUserScreen(personId: 'me'))),
                icon: Icon(Icons.admin_panel_settings_outlined, size: 16, color: tokens.gold),
                label: Text('Admin tools', style: TextStyle(color: tokens.gold, fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            )
          else
            const SizedBox(height: 10),
          Divider(height: 1, color: tokens.line),
          if (places.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.location_on, color: tokens.brand, size: 22),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Places I've been", style: TextStyle(color: tokens.ink, fontSize: 16.5, fontWeight: FontWeight.w800)),
                      Text('From your tagged memories', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlacesBeenScreen(personId: 'me'))),
                  child: Row(
                    children: [
                      Text('See all', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 13.5)),
                      Icon(Icons.chevron_right_rounded, color: tokens.orange),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 116,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = (constraints.maxWidth - 10) / 2;
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: places.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => SizedBox(width: cardWidth, child: PlaceMemoryCard(place: places[i], personId: 'me')),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: tokens.line),
          ],
          const SizedBox(height: 14),
          Text('Memories', style: TextStyle(color: tokens.ink, fontSize: 18, fontWeight: FontWeight.w800)),
          if (myStories.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 10),
              child: Text(
                "Post a Story and it'll show up here for $memoryRetentionDays days — tap the bookmark on one to keep it forever.",
                style: TextStyle(color: tokens.mute, fontSize: 13),
              ),
            ),
          for (var mi = 0; mi < months.length; mi++) ...[
            Padding(
              key: _monthKeys[months[mi]],
              padding: const EdgeInsets.only(top: 10, bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(months[mi], style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 14.5)),
                  ),
                  if (mi == 0 && months.length > 1)
                    GestureDetector(
                      onTap: () => _pickMonth(months),
                      child: Icon(Icons.calendar_today_outlined, color: tokens.ink, size: 19),
                    ),
                ],
              ),
            ),
            memoryGrid(byMonth[months[mi]] ?? const <Story>[], withAdd: mi == 0),
          ],
          if (myStories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                'Memories delete after $memoryRetentionDays days unless you bookmark them. Hold one to delete it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.mute, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Edit your picture, username and bio — reached from "Edit profile".
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _handleController;
  late final TextEditingController _bioController;
  // The bio's "12/50" counter only shows while you're editing it.
  final FocusNode _bioFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _handleController = TextEditingController(text: store.me.handle);
    _bioController = TextEditingController(text: store.me.bio);
    _bioFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _handleController.dispose();
    _bioController.dispose();
    _bioFocus.dispose();
    super.dispose();
  }

  /// Picks a new profile photo — the in-app camera or the photo library.
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
    final err = await store.setProfilePhoto(media.file.path);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _changePhotoFromLibrary(AppStore store) async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (picked == null || !mounted) return;
      // Copy into our own documents folder — the picker's temp file isn't
      // guaranteed to stick around.
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/stories');
      if (!await dir.exists()) await dir.create(recursive: true);
      final dest = '${dir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = await File(picked.path).copy(dest);
      if (!mounted) return;
      final err = await store.setProfilePhoto(savedFile.path);
      if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that photo: $e')));
    }
  }

  Future<void> _commitHandle(AppStore store) async {
    if (_handleController.text.trim() == store.me.handle) return;
    final error = await store.setHandle(_handleController.text);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      setState(() => _handleController.text = store.me.handle);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username saved.'), duration: Duration(seconds: 1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    InputDecoration field(String hint, {String? counter, Widget? suffix}) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: tokens.mute),
          filled: true,
          fillColor: tokens.surface,
          counterText: counter,
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tokens.line)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tokens.brand, width: 1.4)),
        );

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Edit profile')),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            Center(
              child: GestureDetector(
                onTap: () => _changePhoto(store),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PersonAvatar(person: store.me, size: 112, preview: false),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle, border: Border.all(color: tokens.bg, width: 3)),
                        child: const Icon(Icons.edit, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => _changePhoto(store),
                child: Text('Change picture', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 10),
            Text('Username', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _handleController,
              onSubmitted: (_) => _commitHandle(store),
              maxLength: 20,
              // Letters, numbers and underscores only.
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]'))],
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 16),
              decoration: field(
                'Pick a username',
                counter: '',
                suffix: IconButton(
                  tooltip: 'Save username',
                  onPressed: () => _commitHandle(store),
                  icon: Icon(Icons.check_circle_outline, color: tokens.brand),
                ),
              ),
            ),
            Text(
              store.isAdmin ? 'As an admin you can change your username any time.' : 'Usernames can only change once every 15 days.',
              style: TextStyle(color: tokens.mute, fontSize: 12),
            ),
            const SizedBox(height: 18),
            Text('Bio', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _bioController,
              focusNode: _bioFocus,
              onChanged: store.setBio,
              maxLength: 50,
              style: TextStyle(color: tokens.ink, fontSize: 15),
              // The "12/50" counter only appears while you're typing.
              decoration: field('Add a bio', counter: _bioFocus.hasFocus ? null : ''),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointsInfoScreen())),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: BorderSide(color: tokens.line),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(Icons.auto_awesome_outlined, color: tokens.brand, size: 18),
              label: Text('Title & name style', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the Profile tab shows when nobody is logged in: no editable
/// picture, name or bio (there's no profile yet) — just what an account
/// gets you, and the buttons to make one or log in.
class _SignedOutProfile extends StatelessWidget {
  const _SignedOutProfile();

  void _openAccount(BuildContext context, bool logIn) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(closeOnSuccess: true, startInLogIn: logIn)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    Widget perk(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.14), shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: tokens.brand),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(color: tokens.mute, fontSize: 13, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        );
    return Scaffold(
      backgroundColor: tokens.bg,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        children: [
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle),
              child: Icon(Icons.person_outline, size: 48, color: tokens.mute),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Make the night yours',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.ink, fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            store.isGuest
                ? "You're browsing as a guest — you can already check out places, join Live Chat and watch Stories. A free account unlocks the rest:"
                : 'A free account takes about a minute and unlocks:',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.mute, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 22),
          perk(Icons.camera_alt_outlined, 'Post Stories', 'Share the night at your spot, and keep your favorites as Memories.'),
          perk(Icons.people_alt_outlined, 'Friends & DMs', 'Add friends, message anyone, start group chats and video calls.'),
          perk(Icons.favorite_border, 'Like & react', 'Heart Stories and react to Live Chat messages.'),
          perk(Icons.badge_outlined, 'Your own profile', 'Pick a username, add a picture and a bio.'),
          perk(Icons.stars_outlined, 'Funky Points', 'Earn points for going out, level up and unlock name styles.'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => _openAccount(context, false),
              style: FilledButton.styleFrom(
                backgroundColor: tokens.brand,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Create a free account', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _openAccount(context, true),
              style: OutlinedButton.styleFrom(
                foregroundColor: tokens.ink,
                side: BorderSide(color: tokens.mute),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('I already have an account — log in', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom sheet that asks "take a new photo or pick one from your
/// library" when you tap the pencil badge on your profile picture.
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

