import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../services/media_cache.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../widgets/ios_ui.dart';
import '../data/app_store.dart';
import 'account_screen.dart';
import '../data/models.dart';
import '../services/screenshot_detector.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import '../widgets/org_badge.dart';
import 'dm_thread_screen.dart';

/// Full-screen Story playback — tap the right half to advance, the left
/// half to go back, down-arrow/back button to close, and swipe left/right
/// to jump straight to the next/previous PERSON's stories entirely (same
/// queue and order as the rings on Home — "Your story" first, then
/// everyone else, unseen first). Opened by tapping a story ring on Home.
class StoryViewerScreen extends StatefulWidget {
  // The full ordered queue of people this viewer can swipe between — same
  // list Home built its rings from — and which one to open on first.
  final List<String> personIds;
  final int initialIndex;
  // Which of that one person's own stories to open on (0 = their oldest,
  // matching the oldest-first order this viewer plays in) — lets a tap on
  // a specific memory on the Profile page jump straight to that memory
  // instead of always starting from the very first one.
  final int initialStoryIndex;
  // false (rings): only Stories from the last 24 hours. true (tapping a
  // Memory on a profile): everything that person lets you see.
  final bool memories;
  // Opened from Home's area rings: only stories posted inside your area.
  final bool nearOnly;
  const StoryViewerScreen({
    super.key,
    required this.personIds,
    this.initialIndex = 0,
    this.initialStoryIndex = 0,
    this.memories = false,
    this.nearOnly = false,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late int _personIndex = widget.initialIndex.clamp(0, widget.personIds.length - 1);
  late int _i = widget.initialStoryIndex < 0 ? 0 : widget.initialStoryIndex;
  String? _lastRecordedView;
  String? _currentStoryId;

  VideoPlayerController? _videoController;
  // The story whose video already finished and moved us on.
  String? _endedFor;

  // Closing more than once (a video ending + a swipe at the same moment)
  // used to pop the screen underneath too and leave a black screen.
  bool _closing = false;
  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }
  String? _videoForStoryId;

  // Vertical swipe-to-dismiss (rule: "u can swipe out") — drag down far
  // enough, or flick down fast enough, and the viewer closes instead of
  // only ever closing via the X button or tapping through to the end.
  double _dragDy = 0;

  // Which way the most recent story change went — true for "forward" (next
  // story/person, tap-right or swipe-left), false for "back" (tap-left or
  // swipe-right). Read by the content AnimatedSwitcher below to slide the
  // new story in from the correct side and push the old one out the other
  // way, instead of just cutting straight to it.
  bool _forward = true;

  @override
  void initState() {
    super.initState();
    // Screenshot events arrive from native code any time while this screen
    // is open — always attributed to whichever story is on screen right now.
    ScreenshotDetector.start(() {
      final id = _currentStoryId;
      if (id != null && mounted) context.read<AppStore>().recordScreenshot(id);
    });
  }

  @override
  void dispose() {
    ScreenshotDetector.stop();
    _videoController?.dispose();
    super.dispose();
  }

  bool _savingMedia = false;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Downloads a remote (signed-URL) photo/video to a temp file so it can be
  /// handed to the camera-roll saver — a Memory that was posted from another
  /// of your devices has no local file here, only the URL.
  Future<String> _downloadToTemp(String url, String ext) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/funky_save_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await response.pipe(file.openWrite());
      return file.path;
    } finally {
      client.close();
    }
  }

  /// Saves a Story/Memory's photo or video to the phone's own Camera Roll —
  /// the download button in the viewer header. Handles both a local file and a remote signed URL.
  Future<void> _saveStoryToCameraRoll(Story story) async {
    if (_savingMedia) return;
    final hasVideo = story.videoPath != null || story.videoUrl != null;
    final hasImage = story.imagePath != null || story.imageUrl != null;
    if (!hasVideo && !hasImage) {
      _toast('This one is just text — there is no photo or video to save.');
      return;
    }
    setState(() => _savingMedia = true);
    try {
      var hasAccess = await Gal.hasAccess();
      if (!hasAccess) hasAccess = await Gal.requestAccess();
      if (!hasAccess) {
        _toast("Couldn't save — FUNKY needs photo library access.");
        return;
      }
      final String filePath;
      final local = hasVideo ? story.videoPath : story.imagePath;
      if (local != null && File(local).existsSync()) {
        filePath = local;
      } else {
        final url = hasVideo ? story.videoUrl : story.imageUrl;
        if (url == null) {
          _toast("Couldn't save — that file is no longer on this device.");
          return;
        }
        filePath = await _downloadToTemp(url, hasVideo ? 'mp4' : 'jpg');
      }
      if (hasVideo) {
        await Gal.putVideo(filePath);
      } else {
        await Gal.putImage(filePath);
      }
      _toast('Saved to your camera roll.');
    } catch (e) {
      _toast("Couldn't save: $e");
    } finally {
      if (mounted) setState(() => _savingMedia = false);
    }
  }

  bool _reporting = false;

  /// The flag in the header: pick a reason and the Story goes to the FUNKY
  /// admins to review (with who really posted it, even if it's anonymous).
  /// The video pauses while the sheet is open.
  Future<void> _reportStory(Story story) async {
    if (_reporting) return;
    final store = context.read<AppStore>();
    final video = _videoController;
    final wasPlaying = video != null && video.value.isPlaying;
    if (wasPlaying) await video.pause();
    if (!mounted) return;
    final reason = await showIosActionSheet<String>(
      context,
      title: 'Report this story',
      message: "What's wrong with it? Reports are private. The FUNKY team reviews every one.",
      actions: [for (final r in AppStore.storyReportReasons) IosSheetAction(r, r)],
    );
    if (!mounted) return;
    if (reason == null) {
      if (wasPlaying && identical(_videoController, video)) await video.play();
      return;
    }
    setState(() => _reporting = true);
    final msg = await store.reportStory(story, reason);
    if (!mounted) return;
    setState(() => _reporting = false);
    _toast(msg);
    if (wasPlaying && identical(_videoController, video)) await video.play();
  }

  void _ensureVideoFor(Story story, VoidCallback advance) {
    // A local file (your own just-captured Story) takes priority; a remote
    // signed URL (someone else's real-backend Story) is the fallback — see
    // Story.videoUrl's doc comment in models.dart.
    if (story.videoPath == null && story.videoUrl == null) {
      _videoController?.dispose();
      _videoController = null;
      _videoForStoryId = null;
      return;
    }
    if (_videoForStoryId == story.id) return;
    _videoForStoryId = story.id;
    final old = _videoController;
    _videoController = null;
    old?.dispose();
    // Someone else's video is downloaded once and kept on the phone, so
    // watching it again doesn't download it again.
    unawaited(_openVideo(story, advance));
  }

  Future<void> _openVideo(Story story, VoidCallback advance) async {
    final controller = await openVideoController(path: story.videoPath, url: story.videoUrl);
    if (!mounted || _videoForStoryId != story.id) {
      unawaited(controller.dispose());
      return;
    }
    controller.addListener(() {
      final value = controller.value;
      // Fires over and over once a video sits at its end — only move on once.
      if (value.isInitialized && !value.isPlaying && value.position >= value.duration && value.duration > Duration.zero && _endedFor != story.id) {
        _endedFor = story.id;
        advance();
      }
    });
    controller.setVolume(1);
    _videoController = controller;
    try {
      await controller.initialize();
    } catch (_) {
      return;
    }
    if (!mounted || _videoForStoryId != story.id) return;
    controller.play();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final personId = widget.personIds[_personIndex];
    final person = store.personById(personId);
    // Oldest first, like watching through the night in order. Non-friends
    // only ever get tonight's — memories are friends-only (visibleStoriesByUser).
    final stories = (widget.memories
            ? store.visibleStoriesByUser(personId).where((s) => personId == 'me' || !s.anon).toList()
            : store.liveStoriesByUser(personId).where((s) => !widget.nearOnly || store.isStoryNearby(s)).toList())
        .reversed
        .toList(growable: false);

    if (person == null || stories.isEmpty) {
      // Nothing left to show for THIS person (they deleted it, or the 2 PM
      // reset hit) — skip straight to the next one in the queue instead of
      // just bailing out of the whole viewer, same as running out of their
      // stories normally would.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_personIndex < widget.personIds.length - 1) {
          setState(() {
            _forward = true;
            _personIndex++;
            _i = 0;
          });
        } else {
          _close();
        }
      });
      return const Scaffold(backgroundColor: Colors.black, body: SizedBox.shrink());
    }

    if (_i >= stories.length) _i = stories.length - 1;
    final story = stories[_i];
    _currentStoryId = story.id;
    // Record the view once per story, after this frame — never during
    // build, since that would call notifyListeners mid-build.
    if (_lastRecordedView != story.id) {
      _lastRecordedView = story.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppStore>().recordStoryView(story.id);
      });
    }
    final liked = story.likes.contains('me');

    // Jumps straight to the next/previous PERSON's stories, skipping
    // whatever's left of the current one — this is what a left/right swipe
    // does, as opposed to tapping through one story at a time.
    void nextPerson() {
      if (_personIndex < widget.personIds.length - 1) {
        setState(() {
          _forward = true;
          _personIndex++;
          _i = 0;
        });
      } else {
        _close();
      }
    }

    void previousPerson() {
      if (_personIndex > 0) {
        setState(() {
          _forward = false;
          _personIndex--;
          _i = 0;
        });
      }
    }

    void advance() {
      if (_i < stories.length - 1) {
        setState(() {
          _forward = true;
          _i++;
        });
      } else {
        // Ran out of this person's stories by tapping through them one at a
        // time — used to just close the whole viewer here; now it flows
        // straight into the next person, same as a left swipe would.
        nextPerson();
      }
    }

    void back() {
      if (_i > 0) {
        setState(() {
          _forward = false;
          _i--;
        });
      }
    }

    // Swipe up on your OWN story — a bottom sheet with its view count and a
    // delete option. Deleting just lets the next build naturally show
    // whatever's now at this same index (or fall through to the "ran out of
    // stories" / next-person logic above if that was the last one) rather
    // than this code having to special-case what comes next itself.
    void showOwnStorySheet() {
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF1C1C1E),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ViewersList(storyId: story.id),
                if (story.screenshotBy.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.camera_alt_outlined, color: Colors.orangeAccent, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '${story.screenshotBy.length} screenshotted',
                        style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                const SizedBox(height: 12),
                // Text-only Stories never become Memories, so there's nothing
                // to save for those.
                if (context.read<AppStore>().isMemoryStory(story)) ...[
                  // Memories auto-delete memoryRetentionDays after posting —
                  // this is the other place (besides the bookmark on the
                  // Memory card itself) to pin one to the Timeline forever.
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        final store = context.read<AppStore>();
                        if (story.savedToTimeline) {
                          store.removeFromTimeline(story.id);
                        } else {
                          store.saveToTimeline(story.id);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: story.savedToTimeline ? Colors.white54 : Colors.amberAccent),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: Icon(
                        story.savedToTimeline ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
                        color: story.savedToTimeline ? Colors.white70 : Colors.amberAccent,
                      ),
                      label: Text(
                        story.savedToTimeline ? 'Remove from Timeline' : 'Save to Timeline',
                        style: TextStyle(
                          color: story.savedToTimeline ? Colors.white70 : Colors.amberAccent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    story.savedToTimeline
                        ? 'This memory is saved forever.'
                        : 'Memories delete $memoryRetentionDays days after posting unless saved. Stories at a place save automatically.',
                    style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                  ),
                ] else
                  const Text(
                    "Text stories disappear after 24 hours. They don't go to Memories.",
                    style: TextStyle(color: Colors.white38, fontSize: 11.5),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      context.read<AppStore>().deleteStory(story.id);
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    label: const Text('Delete this Story', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Swipe up on someone ELSE's story opens a DM with them — "anyone can
    // message anyone" straight from what they just posted, Snapchat-style.
    void messageFromStory() {
      // The DM opens "replying to" this Story, so the message lands in the
      // chat with a little preview of what you swiped up on.
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: person.id, replyToStory: story)));
    }

    void handleSwipeUp() {
      if (story.uid == 'me') {
        showOwnStorySheet();
      } else if (story.anon) {
        // Messaging would give away who posted it.
        return;
      } else {
        messageFromStory();
      }
    }

    _ensureVideoFor(story, advance);

    // The picture/video fills the whole screen edge to edge (no black bars);
    // the header, hint and buttons are pushed in by the notch / home-bar
    // insets themselves instead.
    final pad = MediaQuery.paddingOf(context);
    // Where it was posted, shown next to the time: "26m ago · 📍 Taverns Bar".
    String? whereLabel = story.placeName;
    if (whereLabel == null && story.place != null && story.place != 'main') {
      for (final pl in store.places) {
        if (pl.id == story.place) {
          whereLabel = pl.name;
          break;
        }
      }
    }
    final whenLabel = whereLabel == null || whereLabel.isEmpty ? timeAgoLabel(story.t) : '${timeAgoLabel(story.t)} · 📍 $whereLabel';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        bottom: false,
        child: GestureDetector(
          onVerticalDragUpdate: (details) => setState(() => _dragDy = (_dragDy + details.delta.dy).clamp(0, 400)),
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (_dragDy > 90 || velocity > 700) {
              _close();
            } else if (_dragDy == 0 && velocity < -500) {
              // Only counts as the swipe-up gesture if you weren't already
              // mid-way through a downward drag-to-dismiss (_dragDy == 0) —
              // keeps the two gestures from fighting over the same flick.
              handleSwipeUp();
            } else {
              setState(() => _dragDy = 0);
            }
          },
          // A fast-enough horizontal swipe skips straight to the next/
          // previous person's stories — same queue and order as the rings
          // on Home — distinct from tapping the left/right half, which
          // steps one story at a time within the current person's own set.
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -300) {
              nextPerson();
            } else if (velocity > 300) {
              previousPerson();
            }
          },
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: Opacity(
              opacity: 1 - (_dragDy / 400).clamp(0.0, 0.6),
              child: Stack(
          children: [
            // Content — slides in from the direction you came from (right
            // for next/swipe-left, left for back/swipe-right) while the
            // previous story slides out the opposite way, instead of just
            // cutting straight to the next image/video/text. Keyed by
            // story id, not by loading state, so a video finishing its
            // spinner-to-playback switch never re-triggers this transition
            // — only an actual story change does.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) {
                final dir = _forward ? 1.0 : -1.0;
                final isExiting = animation.status == AnimationStatus.reverse;
                final offsetTween = Tween<Offset>(
                  begin: Offset(isExiting ? -dir : dir, 0),
                  end: Offset.zero,
                );
                return ClipRect(
                  child: SlideTransition(
                    position: offsetTween.animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey(story.id),
                child: story.videoPath != null || story.videoUrl != null
                    ? (_videoController != null && _videoController!.value.isInitialized
                        ? SizedBox.expand(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              clipBehavior: Clip.hardEdge,
                              child: SizedBox(
                                width: _videoController!.value.size.width,
                                height: _videoController!.value.size.height,
                                child: VideoPlayer(_videoController!),
                              ),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator(color: Colors.white)))
                    : story.imagePath != null
                        ? SizedBox.expand(child: Image.file(File(story.imagePath!), fit: BoxFit.cover))
                        : story.imageUrl != null
                            ? SizedBox.expand(child: netImage(story.imageUrl!, fit: BoxFit.cover))
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 28),
                                  child: story.text != null && story.text!.isNotEmpty
                                      ? Text(
                                          story.text!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, height: 1.3),
                                        )
                                      : const Text('📸', style: TextStyle(fontSize: 48)),
                                ),
                              ),
              ),
            ),
            // A photo/video Story can still carry a caption — show it near
            // the bottom so it doesn't compete with the media itself.
            if ((story.imagePath != null || story.videoPath != null || story.imageUrl != null || story.videoUrl != null) &&
                story.text != null &&
                story.text!.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: pad.bottom + 72,
                child: Text(
                  story.text!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, shadows: [Shadow(color: Colors.black, blurRadius: 6)]),
                ),
              ),
            // Tap zones
            Row(
              children: [
                Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: back)),
                Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: advance)),
              ],
            ),
            // Soft shade behind the header and the bottom hint so the white
            // text stays readable over a bright picture.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: pad.top + 110,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent]),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: pad.bottom + 110,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black54, Colors.transparent]),
                  ),
                ),
              ),
            ),
            // Progress bars
            Positioned(
              top: pad.top + 8,
              left: 10,
              right: 10,
              child: Row(
                children: List.generate(stories.length, (i) {
                  Widget fill(double f) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: f.clamp(0.0, 1.0),
                        child: Container(color: Colors.white),
                      );
                  // Finished stories are full, upcoming ones empty, and the
                  // one playing a video fills up in step with the video;
                  // a photo/text story just shows full while it's on screen.
                  final videoController = _videoController;
                  final Widget inner;
                  if (i < _i) {
                    inner = fill(1);
                  } else if (i > _i) {
                    inner = const SizedBox.shrink();
                  } else if (videoController != null && _videoForStoryId == story.id) {
                    inner = ValueListenableBuilder<VideoPlayerValue>(
                      key: ValueKey('progress_${story.id}'),
                      valueListenable: videoController,
                      builder: (_, v, __) {
                        final total = v.duration.inMilliseconds;
                        final f = v.isInitialized && total > 0 ? v.position.inMilliseconds / total : 0.0;
                        return TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: f.clamp(0.0, 1.0)),
                          duration: const Duration(milliseconds: 500),
                          builder: (_, value, __) => fill(value),
                        );
                      },
                    );
                  } else {
                    inner = fill(1);
                  }
                  return Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: inner,
                    ),
                  );
                }),
              ),
            ),
            // Header
            Positioned(
              top: pad.top + 20,
              left: 14,
              right: 14,
              child: Row(
                children: [
                  // Tapping the avatar/name opens that person's profile —
                  // your own profile (the full tab, not the "someone else's"
                  // card) when it's your own Story, otherwise their public
                  // profile. Anonymous posts don't reveal who it is, so
                  // there's nothing to tap through to there.
                  Expanded(
                    child: story.anon
                        ? Row(
                            children: [
                              const GhostAvatar(size: 32),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('anonymous', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                                  Text(whenLabel, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ],
                          )
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => openProfile(context, story.uid),
                            child: Row(
                              children: [
                                PersonAvatar(person: person, size: 32),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      StyledName(
                                        person: person,
                                        text: '@${person.handle}',
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                                      ),
                                      Text(whenLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  // Download — save this photo/video to your camera roll.
                  // Only your own Stories/Memories get it.
                  if (story.uid == 'me')
                    IconButton(
                      onPressed: _savingMedia ? null : () => _saveStoryToCameraRoll(story),
                      tooltip: 'Save to camera roll',
                      icon: _savingMedia
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.download_outlined, color: Colors.white),
                    ),
                  // Report — anyone else's Story (anonymous ones included).
                  if (story.uid != 'me')
                    IconButton(
                      onPressed: _reporting ? null : () => _reportStory(story),
                      tooltip: 'Report this story',
                      icon: const Icon(Icons.flag_outlined, color: Colors.white),
                    ),
                  IconButton(
                    onPressed: _close,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            // The frat/school letters of where it was posted, small, top right.
            if (storyOrgBadge(store, story) != null)
              Positioned(
                top: pad.top + 68,
                right: 18,
                child: OrgLettersBadge(badge: storyOrgBadge(store, story)!, small: true),
              ),
            // Like button
            Positioned(
              bottom: pad.bottom + 24,
              right: 18,
              child: IconButton(
                onPressed: () => requireAccountThen(context, store, () => store.likeStory(story.id)),
                icon: Icon(liked ? Icons.favorite : Icons.favorite_border, color: liked ? Colors.redAccent : Colors.white, size: 30),
              ),
            ),
            // A quiet hint that the swipe-up gesture exists at all — it has
            // no tap target of its own (the whole-screen GestureDetector
            // above already handles the real gesture), just a nudge. None on
            // someone's anonymous story (messaging them would give it away).
            if (story.uid == 'me' || !story.anon)
            Positioned(
              bottom: pad.bottom + 28,
              left: 0,
              right: 70,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 20),
                    Text(
                      story.uid == 'me' ? 'Swipe up for viewers & delete' : 'Swipe up to message',
                      style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who has seen your Story, newest first, with a heart beside anyone who
/// liked it. Reads live from the store so new views/likes appear while the
/// sheet is open; unknown viewers' profiles are fetched when it opens.
class _ViewersList extends StatefulWidget {
  final String storyId;
  const _ViewersList({required this.storyId});

  @override
  State<_ViewersList> createState() => _ViewersListState();
}

class _ViewersListState extends State<_ViewersList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AppStore>();
      final i = store.stories.indexWhere((s) => s.id == widget.storyId);
      if (i == -1) return;
      final ids = {...store.stories[i].views, ...store.stories[i].likes};
      store.loadPeople(ids);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final i = store.stories.indexWhere((s) => s.id == widget.storyId);
    if (i == -1) return const SizedBox.shrink();
    final story = store.stories[i];
    final liked = story.likes.where((id) => id != 'me').toSet();
    // Newest viewer first; a liker who somehow has no view row still shows.
    final ids = <String>[
      ...story.views.reversed.where((id) => id != 'me'),
      ...liked.where((id) => !story.views.contains(id)),
    ];
    final seen = <String>{};
    final viewers = ids.where(seen.add).toList();
    final count = viewers.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.remove_red_eye_outlined, color: Colors.white70, size: 20),
            const SizedBox(width: 8),
            Text('$count view${count == 1 ? '' : 's'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            if (liked.isNotEmpty) ...[
              const SizedBox(width: 14),
              const Icon(Icons.favorite, color: Colors.redAccent, size: 18),
              const SizedBox(width: 4),
              Text('${liked.length}', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800, fontSize: 16)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (viewers.isEmpty)
          const Text('No one has seen this yet.', style: TextStyle(color: Colors.white54, fontSize: 13))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: viewers.length,
              itemBuilder: (_, k) {
                final id = viewers[k];
                final person = store.personById(id);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      if (person != null) PersonAvatar(person: person, size: 30) else const GhostAvatar(size: 30),
                      const SizedBox(width: 10),
                      Expanded(
                        child: person != null
                            ? StyledName(
                                person: person,
                                text: '@${person.handle}',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                              )
                            : const Text('Someone', style: TextStyle(color: Colors.white54)),
                      ),
                      if (liked.contains(id)) const Icon(Icons.favorite, color: Colors.redAccent, size: 20),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
