import 'package:flutter/material.dart';
import '../theme/colors.dart';

/// A centered line inside a chat saying a video call happened:
/// "@sean started a video chat" with how it went underneath.
class CallLogLine extends StatelessWidget {
  final ThemeTokens tokens;
  final String title;
  final String subtitle;
  final bool missed;
  final DateTime at;
  const CallLogLine({super.key, required this.tokens, required this.title, required this.subtitle, required this.at, this.missed = false});

  String get _time {
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m ${at.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    final accent = missed ? tokens.danger : tokens.brand;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: missed ? tokens.danger.withValues(alpha: 0.5) : tokens.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(missed ? Icons.videocam_off_outlined : Icons.videocam_outlined, size: 20, color: accent),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13.5)),
                    const SizedBox(height: 1),
                    Text('$subtitle · $_time', style: TextStyle(color: missed ? tokens.danger : tokens.mute, fontSize: 12)),
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
