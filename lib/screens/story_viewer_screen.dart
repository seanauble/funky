import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../services/screenshot_detector.dart';
import '../widgets/ui_widgets.dart';
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
  const StoryViewerScreen({super.key, required this.personIds, this.initialIndex = 0, this.initialStoryIndex = 0});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late int _personIndex = widget.initialIndex.clamp(0, widget.personIds.length - 1);
  late int _i = widget.initialStoryIndex < 0 ? 0 : widget.initialStoryIndex;
  String? _lastRecordedView;
  String? _currentStoryId;

  VideoPlayerController? _videoController;
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

  void _ensureVideoFor(Story story, VoidCallback advance) {
    if (story.videoPath == null) {
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
    final controller = VideoPlayerController.file(File(story.videoPath!));
    controller.addListener(() {
      final value = controller.value;
      if (value.isInitialized && !value.isPlaying && value.position >= value.duration && value.duration > Duration.zero) {
        advance();
      }
    });
    controller.setVolume(1);
    controller.initialize().then((_) {
      if (!mounted || _videoForStoryId != story.id) return;
      controller.play();
      setState(() {});
    });
    _videoController = controller;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final personId = widget.personIds[_personIndex];
    final person = store.personById(personId);
    // Oldest first, like watching through the night in order. Non-friends
    // only ever get tonight's — memories are friends-only (visibleStoriesByUser).
    final stories = store.visibleStoriesByUser(personId).reversed.toList(growable: false);

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
          Navigator.of(context).pop();
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
        Navigator.of(context).pop();
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
                Row(
                  children: [
                    const Icon(Icons.remove_red_eye_outlined, color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${story.views.length} view${story.views.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ],
                ),
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
                const SizedBox(height: 20),
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
                      : 'Memories auto-delete $memoryRetentionDays days after posting unless saved.',
                  style: const TextStyle(color: Colors.white38, fontSize: 11.5),
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
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: person.id)));
    }

    void handleSwipeUp() {
      if (story.uid == 'me') {
        showOwnStorySheet();
      } else {
        messageFromStory();
      }
    }

    _ensureVideoFor(story, advance);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onVerticalDragUpdate: (details) => setState(() => _dragDy = (_dragDy + details.delta.dy).clamp(0, 400)),
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (_dragDy > 90 || velocity > 700) {
              Navigator.of(context).pop();
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
                child: story.videoPath != null
                    ? Center(
                        child: _videoController != null && _videoController!.value.isInitialized
                            ? AspectRatio(
                                aspectRatio: _videoController!.value.aspectRatio,
                                child: VideoPlayer(_videoController!),
                              )
                            : const CircularProgressIndicator(color: Colors.white),
                      )
                    : story.imagePath != null
                        ? Center(child: Image.file(File(story.imagePath!), fit: BoxFit.contain))
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
            if ((story.imagePath != null || story.videoPath != null) && story.text != null && story.text!.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 72,
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
            // Progress bars
            Positioned(
              top: 8,
              left: 10,
              right: 10,
              child: Row(
                children: List.generate(stories.length, (i) {
                  return Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i <= _i ? Colors.white : Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),
            // Header
            Positioned(
              top: 20,
              left: 14,
              right: 14,
              child: Row(
                children: [
                  FunkyAvatar(seed: person.id, label: person.handle.isNotEmpty ? person.handle : '?', size: 32, photoPath: person.photoPath),
                  const SizedBox(width: 10),
                  Expanded(
                    child: story.anon
                        ? const Text('anonymous', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))
                        : StyledName(
                            person: person,
                            text: '@${person.handle}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            // Like button
            Positioned(
              bottom: 24,
              right: 18,
              child: IconButton(
                onPressed: () => store.likeStory(story.id),
                icon: Icon(liked ? Icons.favorite : Icons.favorite_border, color: liked ? Colors.redAccent : Colors.white, size: 30),
              ),
            ),
            // A quiet hint that the swipe-up gesture exists at all — it has
            // no tap target of its own (the whole-screen GestureDetector
            // above already handles the real gesture), just a nudge.
            Positioned(
              bottom: 28,
              left: 0,
              right: 70,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 20),
                    Text(
                      story.uid == 'me' ? 'Swipe up for views & delete' : 'Swipe up to message',
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
