import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
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
    super.dispose();
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Content
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
