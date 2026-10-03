import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../services/screenshot_detector.dart';
import '../widgets/ui_widgets.dart';

/// Full-screen Story playback for one person — tap the right half to
/// advance, the left half to go back, down-arrow/back button to close.
/// Opened by tapping a story ring on Home (this screen didn't exist before,
/// which is why tapping a story ring used to do nothing).
class StoryViewerScreen extends StatefulWidget {
  final String personId;
  const StoryViewerScreen({super.key, required this.personId});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  int _i = 0;
  String? _lastRecordedView;
  String? _currentStoryId;

  VideoPlayerController? _videoController;
  String? _videoForStoryId;

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
    final person = store.personById(widget.personId);
    // Oldest first, like watching through the night in order.
    final stories = store.storiesByUser(widget.personId).reversed.toList(growable: false);

    if (person == null || stories.isEmpty) {
      // Nothing left to show (they deleted it, or the 4 PM reset hit) — bail out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
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

    void advance() {
      if (_i < stories.length - 1) {
        setState(() => _i++);
      } else {
        Navigator.of(context).pop();
      }
    }

    void back() {
      if (_i > 0) setState(() => _i--);
    }

    _ensureVideoFor(story, advance);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Content
            if (story.videoPath != null)
              Center(
                child: _videoController != null && _videoController!.value.isInitialized
                    ? AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      )
                    : const CircularProgressIndicator(color: Colors.white),
              )
            else if (story.imagePath != null)
              Center(child: Image.file(File(story.imagePath!), fit: BoxFit.contain))
            else
              Center(
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
                  FunkyAvatar(seed: person.id, label: person.handle.isNotEmpty ? person.handle : '?', size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      story.anon ? 'anonymous' : '@${person.handle}',
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
    );
  }
}
