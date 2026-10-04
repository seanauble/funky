import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../services/screenshot_detector.dart';
import '../widgets/ui_widgets.dart';

/// Full-screen Story playback for everything posted AT one venue tonight —
/// the "tap the venue's banner to see its Stories" flow, as opposed to
/// StoryViewerScreen which plays through one PERSON's Stories. Several
/// different people's Stories can be mixed together here, so (unlike the
/// per-person viewer) the header re-looks-up the author for every story.
class PlaceStoryViewerScreen extends StatefulWidget {
  final String placeId;
  final String placeName;
  const PlaceStoryViewerScreen({super.key, required this.placeId, required this.placeName});

  @override
  State<PlaceStoryViewerScreen> createState() => _PlaceStoryViewerScreenState();
}

class _PlaceStoryViewerScreenState extends State<PlaceStoryViewerScreen> {
  int _i = 0;
  String? _lastRecordedView;
  String? _currentStoryId;

  VideoPlayerController? _videoController;
  String? _videoForStoryId;

  // Vertical swipe-to-dismiss — same as the per-person StoryViewerScreen.
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
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
    // Oldest first, like watching through the night in order.
    final stories = store.storiesFor(widget.placeId).toList()..sort((a, b) => a.t.compareTo(b.t));

    if (stories.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(backgroundColor: Colors.black, body: SizedBox.shrink());
    }

    if (_i >= stories.length) _i = stories.length - 1;
    final story = stories[_i];
    _currentStoryId = story.id;
    final author = store.personById(story.uid);
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
        child: GestureDetector(
          onVerticalDragUpdate: (details) => setState(() => _dragDy = (_dragDy + details.delta.dy).clamp(0, 400)),
          onVerticalDragEnd: (details) {
            if (_dragDy > 90 || (details.primaryVelocity ?? 0) > 700) {
              Navigator.of(context).pop();
            } else {
              setState(() => _dragDy = 0);
            }
          },
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: Opacity(
              opacity: 1 - (_dragDy / 400).clamp(0.0, 0.6),
              child: Stack(
          children: [
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
            Row(
              children: [
                Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: back)),
                Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: advance)),
              ],
            ),
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
            Positioned(
              top: 20,
              left: 14,
              right: 14,
              child: Row(
                children: [
                  FunkyAvatar(seed: story.uid, label: author?.handle.isNotEmpty == true ? author!.handle : '?', size: 32, photoPath: author?.photoPath),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          story.anon ? 'anonymous' : '@${author?.handle ?? '?'}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          widget.placeName,
                          style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
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
