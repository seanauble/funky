import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/ui_widgets.dart';

class _PointRule {
  final String action;
  final String points;
  const _PointRule(this.action, this.points);
}

const _rules = [
  _PointRule('First night using FUNKY', '+25'),
  _PointRule('Vote where you\'re going', '+3'),
  _PointRule('Post a Story at a venue', '+5'),
  _PointRule('Submit a cover / line / capacity report', '+3'),
  _PointRule('Submit a police / shutdown report', '+5'),
  _PointRule('Confirm someone else\'s report', '+2'),
  _PointRule('Your report becomes Verified (8+)', '+15 bonus'),
  _PointRule('Your police/shutdown report becomes Verified', '+20 bonus'),
  _PointRule('Add a missing venue', '+10'),
  _PointRule('3-night activity streak', '+10'),
  _PointRule('7-night activity streak', '+30'),
  _PointRule('30-night activity streak', '+100'),
];

/// "What do FUNKY Points do, and how do I get them" — opened by tapping
/// the Funky Points stat on your own profile. The whole system is built so
/// points reward actually-confirmed contributions rather than easy,
/// repeatable busywork (chatting, liking, opening the app never pay out).
class PointsInfoScreen extends StatelessWidget {
  const PointsInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final title = store.myLevelTitle;
    final badges = store.myBadges;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('FUNKY Points')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FunkyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('${store.me.points}', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w900, fontSize: 32)),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text('points · Level ${store.level}', style: TextStyle(color: tokens.mute, fontSize: 14)),
                    ),
                  ],
                ),
                if (title != null) ...[
                  const SizedBox(height: 6),
                  Text('${title.emoji} ${title.title}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Earn 500 points for your first title.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('Your badges', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (badges.isEmpty)
            EmptyNote(text: 'No badges yet — they\'re earned by actually contributing. Keep going out and reporting what you see.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: badges
                  .map((b) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(999)),
                        child: Text('${b.emoji} ${b.label}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                      ))
                  .toList(),
            ),
          const SizedBox(height: 22),
          Text('Level titles', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Purely cosmetic status — separate from report and venue verification.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
          const SizedBox(height: 10),
          FunkyCard(
            child: Column(
              children: levelTitles.reversed.map((t) {
                final reached = store.me.points >= t.threshold;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 56, child: Text('${t.threshold}', style: TextStyle(color: tokens.mute, fontSize: 12.5))),
                      Expanded(
                        child: Text(
                          '${t.emoji} ${t.title}',
                          style: TextStyle(color: reached ? tokens.ink : tokens.mute, fontWeight: reached ? FontWeight.w800 : FontWeight.w500),
                        ),
                      ),
                      if (reached) Icon(Icons.check, size: 16, color: tokens.gold),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 22),
          Text('How to earn points', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'The biggest rewards come from contributing information that other people actually confirm — not from chatting, liking, or just opening the app.',
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          FunkyCard(
            child: Column(
              children: _rules.map((r) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(r.action, style: TextStyle(color: tokens.ink))),
                      Text(r.points, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
