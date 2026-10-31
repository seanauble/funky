import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';
import 'story_viewer_screen.dart';

// Pieces shared by your own Profile tab and someone else's profile:
// memory tiles, "places I've been" cards, the stats row, the title chip and
// the underline tabs.

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _shortMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "October 2026".
String monthLabel(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// "Oct 9".
String shortDateLabel(DateTime d) => '${_shortMonths[d.month - 1]} ${d.day}';

/// 110108 → "110,108".
String formatCount(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

bool storyHasVideo(Story s) => s.videoPath != null || s.videoUrl != null;

/// The picture (or a frame of the video, or the text) for a Story, filling
/// whatever box it's put in.
Widget storyMedia(Story s, ThemeTokens tokens) {
  if (storyHasVideo(s)) {
    return VideoFrameThumbnail(path: s.videoPath, url: s.videoPath == null ? s.videoUrl : null);
  }
  final path = s.imagePath;
  if (path != null && File(path).existsSync()) {
    return Image.file(File(path), fit: BoxFit.cover, width: double.infinity, height: double.infinity);
  }
  if (s.imageUrl != null) {
    return Image.network(
      s.imageUrl!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => Container(color: tokens.raised, alignment: Alignment.center, child: Icon(Icons.broken_image_outlined, color: tokens.mute)),
    );
  }
  return Container(
    color: tokens.raised,
    padding: const EdgeInsets.all(10),
    alignment: Alignment.center,
    child: Text(
      s.text?.isNotEmpty == true ? s.text! : 'Text story',
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600, fontSize: 13),
    ),
  );
}

/// Where a memory was posted, or null for a general (no-place) one.
String? memoryPlaceName(Story s, AppStore store) {
  final id = s.place;
  if (id == null || id == 'main') return null;
  if (s.placeName != null && s.placeName!.isNotEmpty) return s.placeName;
  for (final p in store.places) {
    if (p.id == id) return p.name;
  }
  return null;
}

/// One memory in a profile grid: the media, the date bottom-left, a video
/// icon top-right, and (optionally) a little place tag.
class MemoryTile extends StatelessWidget {
  final Story story;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? placeName;
  // Your own memories: the bookmark that keeps one forever.
  final bool showBookmark;
  final VoidCallback? onBookmark;
  const MemoryTile({
    super.key,
    required this.story,
    required this.onTap,
    this.onLongPress,
    this.placeName,
    this.showBookmark = false,
    this.onBookmark,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    const shadow = [Shadow(blurRadius: 6, color: Colors.black87)];
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            storyMedia(story, tokens),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 9,
              bottom: 8,
              child: Text(
                shortDateLabel(DateTime.fromMillisecondsSinceEpoch(story.t)),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13.5, shadows: shadow),
              ),
            ),
            if (placeName != null)
              Positioned(
                right: 6,
                bottom: 6,
                left: 52,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_on, size: 12, color: Colors.white),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(placeName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (storyHasVideo(story))
              const Positioned(
                top: 7,
                right: 7,
                child: Icon(Icons.videocam_rounded, color: Colors.white, size: 20, shadows: shadow),
              ),
            if (showBookmark)
              Positioned(
                top: 2,
                left: 2,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBookmark,
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      story.savedToTimeline ? Icons.bookmark : Icons.bookmark_outline,
                      size: 19,
                      color: story.savedToTimeline ? tokens.brand : Colors.white,
                      shadows: shadow,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The dashed "+ Add memory" tile at the end of your own grid.
class AddMemoryTile extends StatelessWidget {
  final VoidCallback onTap;
  const AddMemoryTile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        painter: _DashedRRectPainter(color: tokens.mute.withValues(alpha: 0.6), radius: 14),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, color: tokens.brand, size: 40),
              const SizedBox(height: 4),
              Text('Add memory', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600, fontSize: 13.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DashedRRectPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    const dash = 7.0;
    const gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color || old.radius != radius;
}

/// A spot someone has memories at, built from their tagged Stories.
class MemoryPlace {
  final String id;
  final String name;
  final List<Story> stories; // newest first
  const MemoryPlace({required this.id, required this.name, required this.stories});
}

/// Groups [stories] (newest first) by the place they were posted at, most
/// memories first.
List<MemoryPlace> memoryPlacesFrom(List<Story> stories, AppStore store) {
  final byId = <String, List<Story>>{};
  final names = <String, String>{};
  for (final s in stories) {
    final id = s.place;
    if (id == null || id == 'main') continue;
    final name = memoryPlaceName(s, store);
    if (name == null) continue;
    (byId[id] ??= []).add(s);
    names.putIfAbsent(id, () => name);
  }
  final out = [for (final e in byId.entries) MemoryPlace(id: e.key, name: names[e.key]!, stories: e.value)];
  out.sort((a, b) {
    final c = b.stories.length.compareTo(a.stories.length);
    return c != 0 ? c : b.stories.first.t.compareTo(a.stories.first.t);
  });
  return out;
}

/// A "places I've been" card: the place's picture (or the newest memory
/// there), its name and how many memories.
class PlaceMemoryCard extends StatelessWidget {
  final MemoryPlace place;
  final String personId;
  const PlaceMemoryCard({super.key, required this.place, required this.personId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    Place? live;
    for (final p in store.places) {
      if (p.id == place.id) live = p;
    }
    final url = live?.photoUrl ?? live?.coverUrl;
    final Widget image = url != null
        ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => storyMedia(place.stories.first, tokens))
        : storyMedia(place.stories.first, tokens);
    final n = place.stories.length;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlaceMemoriesScreen(personId: personId, placeId: place.id, placeName: place.name)),
      ),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.35, 1],
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 8,
                bottom: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(place.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15.5, height: 1.15)),
                          const SizedBox(height: 3),
                          Text('$n memor${n == 1 ? 'y' : 'ies'}', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 26),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every memory someone has at one place, plus a way into the place itself
/// when it's still listed.
class PlaceMemoriesScreen extends StatelessWidget {
  final String personId;
  final String placeId;
  final String placeName;
  const PlaceMemoriesScreen({super.key, required this.personId, required this.placeId, required this.placeName});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final all = personId == 'me' ? store.myStories : store.visibleStoriesByUser(personId).where((s) => !s.anon).toList();
    final here = all.where((s) => s.place == placeId).toList();
    final stillListed = store.places.any((p) => p.id == placeId);
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(placeName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (stillListed)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId))),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: tokens.line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(Icons.location_on_outlined, color: tokens.brand, size: 18),
                label: Text('Open $placeName', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              ),
            ),
          if (here.isEmpty)
            const EmptyNote(text: 'No memories here anymore.')
          else
            GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.8,
              ),
              itemCount: here.length,
              itemBuilder: (context, i) {
                final s = here[i];
                return MemoryTile(
                  story: s,
                  onTap: () => openMemory(context, store, personId, s),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// All the places someone has memories at, two per row.
class PlacesBeenScreen extends StatelessWidget {
  final String personId;
  const PlacesBeenScreen({super.key, required this.personId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final stories = personId == 'me' ? store.myStories : store.visibleStoriesByUser(personId).where((s) => !s.anon).toList();
    final places = memoryPlacesFrom(stories, store);
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text("Places I've been")),
      body: places.isEmpty
          ? const Padding(padding: EdgeInsets.all(16), child: EmptyNote(text: 'Post a Story at a spot and it shows up here.'))
          : PlacesGrid(places: places, personId: personId, padding: const EdgeInsets.fromLTRB(16, 8, 16, 40)),
    );
  }
}

/// [PlaceMemoryCard]s two to a row.
class PlacesGrid extends StatelessWidget {
  final List<MemoryPlace> places;
  final String personId;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  const PlacesGrid({super.key, required this.places, required this.personId, this.padding = EdgeInsets.zero, this.scrollable = true});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: !scrollable,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: padding,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.3,
      ),
      itemCount: places.length,
      itemBuilder: (_, i) => PlaceMemoryCard(place: places[i], personId: personId),
    );
  }
}

/// Opens the Story viewer on exactly [story] within that person's memories.
void openMemory(BuildContext context, AppStore store, String personId, Story story) {
  // Newest first, same list the viewer plays (anonymous posts never show
  // on someone else's profile).
  final all = store.visibleStoriesByUser(personId).where((s) => personId == 'me' || !s.anon).toList();
  final i = all.indexWhere((s) => s.id == story.id);
  final viewerIndex = i < 0 ? 0 : all.length - 1 - i; // the viewer plays oldest first
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => StoryViewerScreen(personIds: [personId], initialStoryIndex: viewerIndex, memories: true)),
  );
}

/// Three numbers side by side with thin dividers ("110,108 Funky points |
/// 4,405 Level | 4 Friends").
class ProfileStatsRow extends StatelessWidget {
  final List<(String value, String label, VoidCallback? onTap)> stats;
  const ProfileStatsRow({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final children = <Widget>[];
    for (var i = 0; i < stats.length; i++) {
      final (value, label, onTap) = stats[i];
      if (i > 0) children.add(Container(width: 1, height: 44, color: tokens.line));
      children.add(Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 23)),
                ),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: tokens.mute, fontSize: 13.5)),
              ],
            ),
          ),
        ),
      ));
    }
    return Row(children: children);
  }
}

/// The orange "😎 Verified Stud" pill.
class ProfileTitleChip extends StatelessWidget {
  final LevelTitle title;
  const ProfileTitleChip({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
      child: Text(
        '${title.emoji}  ${title.title}',
        style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 13.5),
      ),
    );
  }
}

/// Plain text tabs with an orange underline under the active one.
class UnderlineTabs extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;
  const UnderlineTabs({super.key, required this.labels, required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Text(
                      labels[i],
                      style: TextStyle(
                        color: i == index ? tokens.orange : tokens.mute,
                        fontWeight: i == index ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 3,
                      decoration: BoxDecoration(
                        color: i == index ? tokens.brand : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
