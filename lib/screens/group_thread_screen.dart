import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/group_models.dart';
import '../data/models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'call_screen.dart';
import 'camera_capture_screen.dart';
import 'dm_thread_screen.dart';

/// A searchable list of people with a checkbox each — used to pick who goes
/// in a new group, who to add to one, and who to send a snap to.
class PersonPickList extends StatefulWidget {
  final List<Person> people;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final String emptyText;
  const PersonPickList({
    super.key,
    required this.people,
    required this.selected,
    required this.onToggle,
    this.emptyText = 'No friends to pick yet — add some friends first.',
  });

  @override
  State<PersonPickList> createState() => _PersonPickListState();
}

class _PersonPickListState extends State<PersonPickList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? widget.people : widget.people.where((p) => p.handle.toLowerCase().contains(q)).toList();
    if (widget.people.isEmpty) {
      return Padding(padding: const EdgeInsets.all(20), child: EmptyNote(text: widget.emptyText));
    }
    return Column(
      children: [
        if (widget.people.length > 6)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: tokens.ink),
              decoration: InputDecoration(
                hintText: 'Search friends',
                hintStyle: TextStyle(color: tokens.mute),
                prefixIcon: Icon(Icons.search, color: tokens.mute),
                filled: true,
                fillColor: tokens.raised,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final p = shown[i];
              final on = widget.selected.contains(p.id);
              return ListTile(
                onTap: () => widget.onToggle(p.id),
                leading: PersonAvatar(person: p, size: 38, preview: false),
                title: Text('@${p.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                trailing: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, color: on ? tokens.brand : tokens.mute),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Pick a name and some friends, make a group chat.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};
  bool _busy = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create(AppStore store) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the group a name.')));
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick at least one friend.')));
      return;
    }
    setState(() => _busy = true);
    final id = await store.createGroup(name, _selected.toList());
    if (!mounted) return;
    setState(() => _busy = false);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(store.lastGroupError ?? "Couldn't start that group.")));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => GroupThreadScreen(groupId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('New group')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _nameController,
                maxLength: 40,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: 'Group name (Pregame crew…)',
                  hintStyle: TextStyle(color: tokens.mute, fontWeight: FontWeight.w500),
                  counterText: '',
                  filled: true,
                  fillColor: tokens.raised,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _selected.isEmpty ? 'ADD FRIENDS' : 'ADD FRIENDS · ${_selected.length} PICKED',
                  style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.4),
                ),
              ),
            ),
            Expanded(
              child: PersonPickList(
                people: store.groupablePeople,
                selected: _selected,
                onToggle: (id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : () => requireAccountThen(context, store, () => _create(store)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _busy
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.onOrange))
                      : Text('Create group', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group chat — text, photos and videos, with everyone in the group.
class GroupThreadScreen extends StatefulWidget {
  final String groupId;
  const GroupThreadScreen({super.key, required this.groupId});

  @override
  State<GroupThreadScreen> createState() => _GroupThreadScreenState();
}

class _GroupThreadScreenState extends State<GroupThreadScreen> {
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sendingMedia = false;
  int _shownCount = -1;
  Timer? _callsTimer;

  @override
  void initState() {
    super.initState();
    // Keep the "video call in progress" banner honest while this is open.
    final store = context.read<AppStore>();
    unawaited(store.refreshGroupCalls());
    _callsTimer = Timer.periodic(const Duration(seconds: 20), (_) => store.refreshGroupCalls());
  }

  @override
  void dispose() {
    _callsTimer?.cancel();
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendMedia(AppStore store, String path, bool isVideo) async {
    final error = await store.sendGroupMessage(widget.groupId, '', mediaPath: path, mediaType: isVideo ? 'video' : 'image');
    if (error != null) {
      _toast(error);
      return;
    }
    if (!mounted) return;
    _scrollToEnd();
  }

  void _snap(AppStore store) {
    requireAccountThen(context, store, () async {
      if (!mounted) return;
      final media = await Navigator.of(context).push<CapturedMedia>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraCaptureScreen()),
      );
      if (media == null || !mounted) return;
      await _sendMedia(store, media.file.path, media.isVideo);
    });
  }

  void _upload(AppStore store) {
    requireAccountThen(context, store, () async {
      if (!mounted || _sendingMedia) return;
      setState(() => _sendingMedia = true);
      try {
        final picked = await ImagePicker().pickMedia(imageQuality: 85);
        if (picked == null || !mounted) return;
        final lower = picked.path.toLowerCase();
        final isVideo = const ['.mp4', '.mov', '.m4v', '.3gp', '.webm', '.avi'].any(lower.endsWith);
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/dm_media');
        if (!await dir.exists()) await dir.create(recursive: true);
        final dot = picked.path.lastIndexOf('.');
        final ext = dot == -1 ? (isVideo ? 'mp4' : 'jpg') : picked.path.substring(dot + 1);
        final saved = await File(picked.path).copy('${dir.path}/grp_${DateTime.now().millisecondsSinceEpoch}.$ext');
        if (!mounted) return;
        await _sendMedia(store, saved.path, isVideo);
      } catch (e) {
        _toast('Could not use that file: $e');
      } finally {
        if (mounted) setState(() => _sendingMedia = false);
      }
    });
  }

  void _send(AppStore store) {
    final text = _draftController.text.trim();
    if (text.isEmpty) return;
    requireAccountThen(context, store, () async {
      _draftController.clear();
      final error = await store.sendGroupMessage(widget.groupId, text);
      if (!mounted) return;
      if (error != null) {
        if (_draftController.text.isEmpty) _draftController.text = text;
        _toast(error);
        return;
      }
      _scrollToEnd();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final group = store.groupById(widget.groupId);

    if (group == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This group isn't around anymore.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final msgs = store.messagesFor(group.room);
    if (msgs.length != _shownCount) {
      _shownCount = msgs.length;
      _scrollToEnd();
    }
    var lastMine = -1;
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].uid == 'me') {
        lastMine = i;
        break;
      }
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupInfoScreen(groupId: group.id))),
          child: Row(
            children: [
              GroupAvatar(group: group, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
                    Text('${group.memberIds.length} people', style: TextStyle(color: tokens.mute, fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (store.signedIn)
            IconButton(
              tooltip: store.activeGroupCallId(group.id) != null ? 'Join video call' : 'Start video call',
              onPressed: () => joinGroupVideoCall(context, store, group.id),
              icon: Icon(
                store.activeGroupCallId(group.id) != null ? Icons.videocam : Icons.videocam_outlined,
                color: store.activeGroupCallId(group.id) != null ? tokens.brand : null,
              ),
            ),
          IconButton(
            tooltip: 'Group info',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupInfoScreen(groupId: group.id))),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // A call is going on in this group right now.
            if (store.activeGroupCallId(group.id) != null)
              Material(
                color: tokens.brand,
                child: InkWell(
                  onTap: () => joinGroupVideoCall(context, store, group.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.videocam, color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Video call in progress', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                          child: Text('Join', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: msgs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(child: EmptyNote(text: 'Nothing here yet — say hey to ${group.name}.')),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[i];
                        String? label;
                        if (m.uid == 'me' && (i == lastMine || m.status == 'failed')) {
                          switch (m.status) {
                            case 'sending':
                              label = 'Sending…';
                            case 'failed':
                              label = 'Not sent · tap to retry';
                            default:
                              label = 'Delivered';
                          }
                        }
                        final sender = m.uid == 'me' ? store.me : store.personById(m.uid);
                        if (sender == null) return const SizedBox.shrink();
                        return DmBubble(
                          message: m,
                          tokens: tokens,
                          other: sender,
                          senderLabel: m.uid == 'me' ? null : '@${sender.handle}',
                          statusLabel: label,
                          onRetry: m.status == 'failed' ? () => store.retryDirectMessage(m.id) : null,
                          errorDetail: m.status == 'failed' ? store.sendErrorFor(m.id) : null,
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: tokens.surface, border: Border(top: BorderSide(color: tokens.line))),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Snap a photo or video',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _snap(store),
                      icon: Icon(Icons.photo_camera_outlined, color: tokens.brand),
                    ),
                    IconButton(
                      tooltip: 'Upload a photo or video',
                      visualDensity: VisualDensity.compact,
                      onPressed: _sendingMedia ? null : () => _upload(store),
                      icon: Icon(Icons.photo_library_outlined, color: tokens.brand),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _draftController,
                        maxLength: 240,
                        decoration: InputDecoration(
                          hintText: 'Message ${group.name}',
                          hintStyle: TextStyle(color: tokens.mute),
                          filled: true,
                          fillColor: tokens.raised,
                          counterText: '',
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(19), borderSide: BorderSide.none),
                        ),
                        style: TextStyle(color: tokens.ink),
                        onSubmitted: (_) => _send(store),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _send(store),
                      child: Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle),
                        child: const Icon(Icons.arrow_upward, color: Colors.white, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Group name, who's in it, add people, leave.
class GroupInfoScreen extends StatelessWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  Future<void> _rename(BuildContext context, AppStore store, GroupChat group) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final controller = TextEditingController(text: group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text('Rename group', style: TextStyle(color: tokens.ink)),
        content: TextField(
          controller: controller,
          maxLength: 40,
          autofocus: true,
          style: TextStyle(color: tokens.ink),
          decoration: InputDecoration(hintText: 'Group name', hintStyle: TextStyle(color: tokens.mute)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text('Save', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == group.name) return;
    final error = await store.renameGroup(group.id, name);
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// Pick a new group picture — take one, choose one, or remove it.
  Future<void> _changePhoto(BuildContext context, AppStore store, GroupChat group) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: tokens.ink),
              title: Text('Take a photo', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              onTap: () => Navigator.of(sheetContext).pop('camera'),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: tokens.ink),
              title: Text('Choose from library', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              onTap: () => Navigator.of(sheetContext).pop('library'),
            ),
            if (group.photoUrl != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: tokens.danger),
                title: Text('Remove photo', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    String? path;
    if (choice == 'camera') {
      final media = await Navigator.of(context).push<CapturedMedia>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraCaptureScreen()),
      );
      if (media == null || !context.mounted) return;
      if (media.isVideo) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group pictures are photos only — tap the shutter instead of holding it.')));
        return;
      }
      path = media.file.path;
    } else if (choice == 'library') {
      try {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1280);
        if (picked == null || !context.mounted) return;
        path = picked.path;
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that photo: $e')));
        return;
      }
    }
    final error = await store.setGroupPhoto(group.id, path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? (path == null ? 'Group photo removed.' : 'Group photo updated.'))));
    }
  }

  Future<void> _addPeople(BuildContext context, AppStore store, GroupChat group) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final candidates = store.groupablePeople.where((p) => !group.memberIds.contains(p.id)).toList();
    final picked = <String>{};
    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('Add people', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800))),
                      TextButton(
                        onPressed: picked.isEmpty ? null : () => Navigator.of(sheetContext).pop(picked),
                        child: Text('Add${picked.isEmpty ? '' : ' (${picked.length})'}', style: TextStyle(color: picked.isEmpty ? tokens.mute : tokens.brand, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PersonPickList(
                    people: candidates,
                    selected: picked,
                    emptyText: 'All your friends are already in this group.',
                    onToggle: (id) => setSheet(() => picked.contains(id) ? picked.remove(id) : picked.add(id)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    final error = await store.addGroupMembers(group.id, chosen.toList());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Added.')));
    }
  }

  Future<void> _leave(BuildContext context, AppStore store, GroupChat group) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text('Leave ${group.name}?', style: TextStyle(color: tokens.ink)),
        content: Text("You'll stop getting its messages. Someone can add you back later.", style: TextStyle(color: tokens.mute)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Leave', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final error = await store.leaveGroup(group.id);
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final group = store.groupById(groupId);
    if (group == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: Padding(padding: const EdgeInsets.all(20), child: Text("This group isn't around anymore.", style: TextStyle(color: tokens.ink))),
      );
    }
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Group info')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: () => _changePhoto(context, store, group),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  GroupAvatar(group: group, size: 96),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: tokens.surface, shape: BoxShape.circle, border: Border.all(color: tokens.line, width: 2)),
                      child: Icon(Icons.photo_camera_outlined, size: 17, color: tokens.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: () => _changePhoto(context, store, group),
              child: Text(group.photoUrl == null ? 'Add group photo' : 'Change group photo', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 6),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => _rename(context, store, group),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('GROUP NAME', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 11.5, letterSpacing: 0.4)),
                          const SizedBox(height: 3),
                          Text(group.name, style: TextStyle(color: tokens.ink, fontSize: 18, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_outlined, color: tokens.mute, size: 20),
                  ],
                ),
              ),
            ),
          ),
          SectionHeader(title: '${group.memberIds.length} people'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => _addPeople(context, store, group),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.person_add_alt_1_outlined, color: tokens.brand),
                    const SizedBox(width: 12),
                    Text('Add people', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final id in group.memberIds)
            Builder(builder: (context) {
              final p = id == 'me' ? store.me : store.personById(id);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                onTap: id == 'me' || p == null ? null : () => openProfile(context, id),
                leading: p == null ? CircleAvatar(backgroundColor: tokens.raised) : PersonAvatar(person: p, size: 38, preview: false),
                title: Text(
                  id == 'me' ? 'You' : '@${p?.handle ?? 'someone'}',
                  style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                ),
                subtitle: group.createdBy == id ? Text('Started the group', style: TextStyle(color: tokens.mute, fontSize: 12)) : null,
              );
            }),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _leave(context, store, group),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: BorderSide(color: tokens.danger),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: Icon(Icons.logout, size: 18, color: tokens.danger),
            label: Text('Leave group', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
