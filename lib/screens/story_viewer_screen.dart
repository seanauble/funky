import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../services/screenshot_detector.dart';
import '../widgets/ui_widgets.dart';

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
  const StoryViewerScreen({super.key, required this.personIds, this.initialIndex = 0});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late int _personIndex = widget.initialIndex.clamp(0, widget.personIds.length - 1);
  int _i = 0;
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
    // Oldest first, like watching through the night in order.
    final stories = store.storiesByUser(personId).reversed.toList(growable: false);

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

    _ensureVideoFor(story, advance);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onVerticalDragUpdate: (details) => setState(() => _dragDy = (_dragDy + details.delta.dy).clamp(0, 400)),
          onVerticalDragEnd: (details) {
            if (_dragDy > 90 || (details.primaryVelocity ?? 0) > 700) {
              Navigator.of(context).pop();
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
          ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
