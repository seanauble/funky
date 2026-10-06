import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'camera_capture_screen.dart';

/// A private 1:1 thread with one other person — reached from the Messages
/// tab in Chat, the "Message" button on someone's profile, or swiping up
/// on someone else's Story. Reuses the exact same ChatMessage/sendMessage
/// plumbing as the area live chat, just addressed to a per-pair room (see
/// dmRoomId) instead of 'main'.
///
/// Messages are real: they go through Supabase, show "Sending…" →
/// "Delivered" → "Seen" under your newest message, and can carry a photo or
/// video — snapped with the in-app camera or picked from the library (videos
/// must be under AppStore.maxDmVideoBytes).
class DmThreadScreen extends StatefulWidget {
  final String personId;
  const DmThreadScreen({super.key, required this.personId});

  @override
  State<DmThreadScreen> createState() => _DmThreadScreenState();
}

class _DmThreadScreenState extends State<DmThreadScreen> {
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();

  bool _sendingMedia = false;
  int _shownCount = -1;

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

  Future<void> _sendMedia(AppStore store, String path, bool isVideo) async {
    final error = await store.sendDirectMessage(widget.personId, '', mediaPath: path, mediaType: isVideo ? 'video' : 'image');
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _scrollToEnd();
  }

  /// Camera button — the same in-app camera Stories use: tap the shutter for
  /// a photo, hold it for a video, and it sends the moment you capture.
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

  /// Upload button — pick a photo or video from the library. Anything over
  /// the size limit is rejected BEFORE it's copied or uploaded.
  void _upload(AppStore store) {
    requireAccountThen(context, store, () async {
      if (!mounted || _sendingMedia) return;
      setState(() => _sendingMedia = true);
      try {
        final picked = await ImagePicker().pickMedia(imageQuality: 85);
        if (picked == null || !mounted) return;
        final lower = picked.path.toLowerCase();
        final isVideo = const ['.mp4', '.mov', '.m4v', '.3gp', '.webm', '.avi'].any(lower.endsWith);
        final size = await File(picked.path).length();
        if (!mounted) return;
        if (isVideo && size > AppStore.maxDmVideoBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('That video is too big — keep it under ${AppStore.maxDmVideoBytes ~/ (1024 * 1024)} MB.')),
          );
          return;
        }
        if (!isVideo && size > AppStore.maxDmImageBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('That photo is too big — keep it under ${AppStore.maxDmImageBytes ~/ (1024 * 1024)} MB.')),
          );
          return;
        }
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/dm_media');
        if (!await dir.exists()) await dir.create(recursive: true);
        final dot = picked.path.lastIndexOf('.');
        final ext = dot == -1 ? (isVideo ? 'mp4' : 'jpg') : picked.path.substring(dot + 1);
        final saved = await File(picked.path).copy('${dir.path}/dm_${DateTime.now().millisecondsSinceEpoch}.$ext');
        if (!mounted) return;
        await _sendMedia(store, saved.path, isVideo);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that file: $e')));
      } finally {
        if (mounted) setState(() => _sendingMedia = false);
      }
    });
  }

  @override
  void dispose() {
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send(AppStore store) {
    final text = _draftController.text.trim();
    if (text.isEmpty) return;
    Future<void> doSend() async {
      // Cleared up front so the input doesn't sit full while the real
      // (possibly network) send is in flight — same instant feel as before,
      // now that a real account's send is a genuine await instead of a
      // synchronous local-only write.
      _draftController.clear();
      final error = await store.sendDirectMessage(widget.personId, text);
      if (!mounted) return;
      if (error != null) {
        // Put the text back so a "slow down" doesn't eat what you typed.
        if (_draftController.text.isEmpty) _draftController.text = text;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        return;
      }
      _scrollToEnd();
    }
    requireAccountThen(context, store, doSend);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(widget.personId);

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

    final isFriend = store.isFriendsWith(person.id);
    final room = dmRoomId('me', person.id);
    final msgs = store.messagesFor(room);
    // Opening the thread (or a new message landing while it's open) tells
    // the server you've seen what they sent — idempotent and throttled in
    // the store, so calling it every build is cheap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().markDmSeen(widget.personId);
    });
    // Land on the newest message when the thread opens or something new
    // arrives (yours or theirs).
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
        // The whole avatar + name area is one big tap target straight
        // through to their profile.
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openProfile(context, person.id),
          child: Row(
            children: [
              // Same green-ring treatment as the story rings on Home — makes
              // a friend's thread easier to pick out at a glance from a
              // stranger's.
              Container(
                padding: EdgeInsets.all(isFriend ? 2 : 0),
                decoration: isFriend ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.friend, width: 2)) : null,
                child: FunkyAvatar(
                  seed: person.id,
                  label: person.handle.isNotEmpty ? person.handle : '?',
                  size: 30,
                  photoPath: person.photoPath,
                  photoUrl: person.photoUrl,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: StyledName(person: person, text: '@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15))),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: msgs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: EmptyNote(
                          text: isFriend
                              ? 'Nothing here yet — say hey to @${person.handle}.'
                              : "Nothing here yet — you don't have to be friends to message someone on FUNKY.",
                        ),
                      ),
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
                            case 'seen':
                              label = 'Seen';
                            default:
                              label = 'Delivered';
                          }
                        }
                        return _DmBubble(
                          message: m,
                          tokens: tokens,
                          other: person,
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
                          hintText: 'Message @${person.handle}',
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

class _DmBubble extends StatelessWidget {
  final ChatMessage message;
  final ThemeTokens tokens;
  // The person on the other end of the thread — their small profile picture
  // sits beside each of their bubbles (tap it for the big preview).
  final Person other;
  // "Sending…" / "Delivered" / "Seen" / "Not sent · tap to retry" — shown
  // under your newest message (and under any that failed).
  final String? statusLabel;
  final VoidCallback? onRetry;
  final String? errorDetail;
  const _DmBubble({required this.message, required this.tokens, required this.other, this.statusLabel, this.onRetry, this.errorDetail});

  @override
  Widget build(BuildContext context) {
    final mine = message.uid == 'me';
    final isMedia = message.mediaType != null;
    final textColor = mine ? tokens.onOrange : tokens.ink;
    final bubble = Container(
      padding: isMedia ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.66),
      decoration: BoxDecoration(
        color: mine ? tokens.brand : tokens.raised,
        borderRadius: BorderRadius.circular(16),
      ),
      child: isMedia
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DmMedia(message: message, tokens: tokens),
                if (message.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                    child: filteredMessageText(message.text, TextStyle(color: textColor)),
                  ),
              ],
            )
          : filteredMessageText(message.text, TextStyle(color: textColor)),
    );
    if (mine) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            bubble,
            if (statusLabel != null)
              GestureDetector(
                onTap: onRetry,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3, right: 4),
                  child: Text(
                    statusLabel!,
                    style: TextStyle(
                      color: onRetry != null ? Colors.redAccent : tokens.mute,
                      fontSize: 11.5,
                      fontWeight: onRetry != null ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            if (errorDetail != null)
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 4),
                child: Text(errorDetail!, textAlign: TextAlign.right, style: TextStyle(color: tokens.mute, fontSize: 10.5)),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PersonAvatar(person: other, size: 26),
            ),
            bubble,
          ],
        ),
      ),
    );
  }
}

/// The photo/video thumbnail inside a DM bubble. Your own sends play from the
/// local file; the other person's load from a signed URL. Tap to open it big.
class _DmMedia extends StatelessWidget {
  final ChatMessage message;
  final ThemeTokens tokens;
  const _DmMedia({required this.message, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final isVideo = message.mediaType == 'video';
    final path = message.mediaPath;
    final localOk = path != null && File(path).existsSync();
    final url = message.mediaUrl;
    Widget media;
    if (!localOk && url == null) {
      media = Container(
        color: tokens.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: Text('Photo/video no longer available', textAlign: TextAlign.center, style: TextStyle(color: tokens.mute, fontSize: 12)),
      );
    } else if (isVideo) {
      media = Stack(
        fit: StackFit.expand,
        children: [
          VideoFrameThumbnail(path: localOk ? path : null, url: localOk ? null : url),
          const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 46)),
        ],
      );
    } else if (localOk) {
      media = Image.file(File(path!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: tokens.mute));
    } else {
      media = Image.network(
        url!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: tokens.mute),
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.mute))),
      );
    }
    return GestureDetector(
      onTap: (localOk || url != null)
          ? () => Navigator.of(context).push(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => _DmMediaViewer(path: localOk ? path : null, url: localOk ? null : url, isVideo: isVideo),
                ),
              )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(width: 200, height: 260, child: media),
      ),
    );
  }
}

/// Full-screen view of a DM photo/video, with a button to save it to the
/// camera roll.
class _DmMediaViewer extends StatefulWidget {
  final String? path;
  final String? url;
  final bool isVideo;
  const _DmMediaViewer({required this.path, required this.url, required this.isVideo});

  @override
  State<_DmMediaViewer> createState() => _DmMediaViewerState();
}

class _DmMediaViewerState extends State<_DmMediaViewer> {
  VideoPlayerController? _video;
  bool _videoReady = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final path = widget.path;
    final c = path != null ? VideoPlayerController.file(File(path)) : VideoPlayerController.networkUrl(Uri.parse(widget.url!));
    _video = c;
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() => _videoReady = true);
    } catch (_) {
      if (mounted) _toast("Couldn't play that video.");
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      var access = await Gal.hasAccess();
      if (!access) access = await Gal.requestAccess();
      if (!access) {
        _toast("Couldn't save — FUNKY needs photo library access.");
        return;
      }
      String filePath;
      final local = widget.path;
      if (local != null && File(local).existsSync()) {
        filePath = local;
      } else {
        final url = widget.url;
        if (url == null) {
          _toast("Couldn't save — that file isn't available.");
          return;
        }
        final tmp = await getTemporaryDirectory();
        final dest = File('${tmp.path}/dm_save_${DateTime.now().millisecondsSinceEpoch}.${widget.isVideo ? 'mp4' : 'jpg'}');
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(url));
          final res = await req.close();
          if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
          final sink = dest.openWrite();
          await res.pipe(sink);
        } finally {
          client.close();
        }
        filePath = dest.path;
      }
      if (widget.isVideo) {
        await Gal.putVideo(filePath);
      } else {
        await Gal.putImage(filePath);
      }
      _toast('Saved to your camera roll.');
    } catch (e) {
      _toast("Couldn't save: $e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    Widget body;
    if (widget.isVideo) {
      body = (video != null && _videoReady && video.value.isInitialized)
          ? GestureDetector(
              onTap: () => setState(() {
                if (video.value.isPlaying) {
                  video.pause();
                } else {
                  video.play();
                }
              }),
              child: Center(child: AspectRatio(aspectRatio: video.value.aspectRatio, child: VideoPlayer(video))),
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white70));
    } else {
      final path = widget.path;
      body = InteractiveViewer(
        child: Center(
          child: path != null
              ? Image.file(File(path), fit: BoxFit.contain)
              : Image.network(widget.url!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48)),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Save to camera roll',
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
