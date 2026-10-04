import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/ui_widgets.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _dayLabel(DateTime dt) => '${_months[dt.month - 1]} ${dt.day}, ${dt.year}';

/// Every Story you post is also saved privately here (rule 4) — and, unlike
/// before, it STAYS here: AppStore.load() used to silently drop your own
/// Stories the moment the 2 PM reset hit (it only ever merged them back in
/// on the SAME session, never across a reset), so Memories looked like it
/// kept losing photos/videos. Now it's a real permanent feed, grouped by the
/// day and place you posted — same privacy rule as old Stories on your
/// profile: only your friends can see it, nobody else.
class MemoriesScreen extends StatelessWidget {
  const MemoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final myStories = store.myStories; // newest first already

    // Group by calendar day — stories within a day keep their own place
    // label (via Story.placeName) rather than being bucketed by place too,
    // since one night often touches more than one spot.
    final byDay = <String, List<Story>>{};
    for (final s in myStories) {
      final key = _dayLabel(DateTime.fromMillisecondsSinceEpoch(s.t));
      (byDay[key] ??= []).add(s);
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Memories')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A permanent archive of your own Stories, grouped by day and place — they never disappear at the 2 PM reset anymore. Only your friends can see this, same as old Stories on your profile.',
            style: TextStyle(color: tokens.mute),
          ),
          const SizedBox(height: 16),
          if (myStories.isEmpty)
            const FunkyCard(child: EmptyNote(text: "Nothing saved yet. Post a Story and it'll stay here forever, even after tonight resets."))
          else
            ...byDay.entries.expand((entry) => <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Text(entry.key, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                  ),
                  ...entry.value.map((s) => _MemoryCard(story: s)),
                ]),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  final Story story;
  const _MemoryCard({required this.story});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final dt = DateTime.fromMillisecondsSinceEpoch(story.t);
    final timeLabel = TimeOfDay.fromDateTime(dt).format(context);

    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.place, size: 13, color: tokens.mute),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  story.placeName ?? 'Area-wide',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Text(timeLabel, style: TextStyle(color: tokens.mute, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          if (story.videoPath != null || story.videoUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                alignment: Alignment.bottomLeft,
                children: [
                  Container(height: 140, width: double.infinity, color: Colors.black),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam, color: Colors.white, size: 16),
                        const SizedBox(width: 4),
                        const Text('Video Story', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else if (story.imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(File(story.imagePath!), height: 140, width: double.infinity, fit: BoxFit.cover),
            )
          // A Memory synced from another device you posted it on has no
          // local file here — only the signed URL fetched from the real
          // backend (see Story.imageUrl's doc comment in models.dart).
          else if (story.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(story.imageUrl!, height: 140, width: double.infinity, fit: BoxFit.cover),
            ),
          if (story.videoPath != null || story.imagePath != null || story.videoUrl != null || story.imageUrl != null)
            const SizedBox(height: 8),
          if (story.text != null && story.text!.isNotEmpty)
            Text(story.text!, style: TextStyle(color: tokens.ink))
          else if (story.videoPath == null && story.imagePath == null && story.videoUrl == null && story.imageUrl == null)
            Text('Text story', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.remove_red_eye_outlined, size: 14, color: tokens.mute),
              const SizedBox(width: 4),
              Text('${story.views.length} view${story.views.length == 1 ? '' : 's'}', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
              if (story.screenshotBy.isNotEmpty) ...[
                const SizedBox(width: 14),
                Icon(Icons.camera_alt_outlined, size: 14, color: tokens.orange),
                const SizedBox(width: 4),
                Text(
                  '${story.screenshotBy.length} screenshotted',
                  style: TextStyle(color: tokens.orange, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
