import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import 'ui_widgets.dart';

/// Rule 2's "New day. New moves." screen — shown once, right after the app
/// notices the stored session is from before the last 4 PM reset.
class ResetBanner extends StatelessWidget {
  const ResetBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    if (!store.justReset) return const SizedBox.shrink();

    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'New day. New moves.',
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.orange, fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                "Yesterday's chats, places, polls, and Stories have been cleared. Your Stories are saved in Memories.",
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.mute),
              ),
              const SizedBox(height: 10),
              Text(
                "It's a fresh night. What's the move today?",
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: store.dismissResetBanner,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text("Let's go", style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
