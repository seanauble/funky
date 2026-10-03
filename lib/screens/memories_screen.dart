import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/ui_widgets.dart';

/// Every Story you post is also saved privately here (rule 4). Full
/// "a year ago today" grouping needs more than one real night of history
/// to be meaningful, so for now this lists what you've posted tonight —
/// the grouping and anniversary cards are a near-term follow-up once
/// Stories persist across real nights against a backend.
class MemoriesScreen extends StatelessWidget {
  const MemoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final myStories = store.myStories;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Memories')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A private archive of your own Stories. Friends, DMs, and this page survive the 2 PM reset — nobody else can see it.',
            style: TextStyle(color: tokens.mute),
          ),
          const SizedBox(height: 16),
          if (myStories.isEmpty)
            const FunkyCard(child: EmptyNote(text: "Nothing saved yet. Post a Story tonight and it'll show up here, even after the reset."))
          else
            ...myStories.map((s) {
              final dt = DateTime.fromMillisecondsSinceEpoch(s.t);
              return FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dt.toString(), style: TextStyle(color: tokens.mute, fontSize: 12)),
                    const SizedBox(height: 4),
                    if (s.videoPath != null)
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
                    else if (s.imagePath != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(File(s.imagePath!), height: 140, width: double.infinity, fit: BoxFit.cover),
                      ),
                    if (s.videoPath != null || s.imagePath != null) const SizedBox(height: 8),
                    if (s.text != null && s.text!.isNotEmpty)
                      Text(s.text!, style: TextStyle(color: tokens.ink))
                    else if (s.videoPath == null && s.imagePath == null)
                      Text('Photo story', style: TextStyle(color: tokens.mute)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.remove_red_eye_outlined, size: 14, color: tokens.mute),
                        const SizedBox(width: 4),
                        Text('${s.views.length} view${s.views.length == 1 ? '' : 's'}', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                        if (s.screenshotBy.isNotEmpty) ...[
                          const SizedBox(width: 14),
                          Icon(Icons.camera_alt_outlined, size: 14, color: tokens.orange),
                          const SizedBox(width: 4),
                          Text(
                            '${s.screenshotBy.length} screenshotted',
                            style: TextStyle(color: tokens.orange, fontSize: 12.5, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
