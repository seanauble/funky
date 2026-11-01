import 'package:flutter/material.dart';
import '../data/models.dart';
import 'avatar_preview.dart';
import 'ios_ui.dart';
import 'ui_widgets.dart';

/// "What's the move tonight?" on Home: each spot with its initials, a bar
/// and its share of the vote; your pick outlined in orange; who voted and
/// how long is left along the bottom.
class MovePollCard extends StatelessWidget {
  final List<String> labels;
  final List<int> counts;
  final int? selected;
  final ValueChanged<int> onSelect;
  final List<Person> voters;
  final String timeLeft;

  const MovePollCard({
    super.key,
    required this.labels,
    required this.counts,
    required this.selected,
    required this.onSelect,
    required this.voters,
    required this.timeLeft,
  });

  static const _palette = [
    Color(0xFFC9692F), // orange
    Color(0xFF9B8AF0), // purple
    Color(0xFF4FA97A), // green
    Color(0xFFD966A8), // pink
    Color(0xFF4C8FE6), // blue
  ];

  /// "Charlie's Bar" → "CB", "Josie Kelly's Public House" → "JK".
  static String initials(String name) {
    final words = name.split(RegExp(r'\s+')).where((w) => RegExp(r'[A-Za-z0-9]').hasMatch(w)).toList();
    if (words.isEmpty) return '?';
    String first(String w) => w.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').characters.first.toUpperCase();
    if (words.length == 1) return first(words.first);
    return '${first(words[0])}${first(words[1])}';
  }

  Future<void> _changeVote(BuildContext context) async {
    final picked = await showIosActionSheet<int>(
      context,
      title: "What's the move tonight?",
      actions: [
        for (var i = 0; i < labels.length; i++) IosSheetAction(labels[i], i),
      ],
    );
    if (picked != null) onSelect(picked);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final total = counts.fold<int>(0, (a, b) => a + b);

    Widget row(int i) {
      final share = total == 0 ? 0.0 : counts[i] / total;
      final pct = (share * 100).round();
      final mine = selected == i;
      final color = labels[i] == 'Staying in' ? _palette.last : _palette[i % (_palette.length - 1)];
      return Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
            decoration: BoxDecoration(
              color: mine ? tokens.orange.withValues(alpha: 0.13) : tokens.raised,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: mine ? tokens.orange : Colors.transparent, width: 1.6),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Text(
                    initials(labels[i]),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5),
                            ),
                          ),
                          if (mine) ...[
                            const SizedBox(width: 6),
                            Container(
                              width: 18,
                              height: 18,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: tokens.orange, shape: BoxShape.circle),
                              child: const Icon(Icons.check_rounded, color: Colors.white, size: 13),
                            ),
                            const SizedBox(width: 5),
                            Text('Your pick', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 12.5)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 7),
                      // How much of the vote it has.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: SizedBox(
                          height: 7,
                          child: Stack(
                            children: [
                              Positioned.fill(child: ColoredBox(color: tokens.line.withValues(alpha: 0.55))),
                              FractionallySizedBox(
                                widthFactor: counts[i] == 0 ? 0 : share.clamp(0.04, 1.0),
                                heightFactor: 1,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(color: tokens.orange, borderRadius: BorderRadius.circular(99)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 46,
                  child: Text(
                    '$pct%',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final faces = voters.take(3).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: tokens.line.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("What's the move tonight?", style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 23, letterSpacing: -0.3)),
          const SizedBox(height: 3),
          if (selected != null)
            Row(
              children: [
                Text('Your vote is in', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 14.5)),
                const SizedBox(width: 6),
                Container(
                  width: 19,
                  height: 19,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: tokens.orange, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 14),
                ),
              ],
            )
          else
            Text("Tap where you're headed", style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 14.5)),
          const SizedBox(height: 14),
          for (var i = 0; i < labels.length; i++) row(i),
          const SizedBox(height: 4),
          Row(
            children: [
              if (faces.isNotEmpty) ...[
                SizedBox(
                  width: 20.0 * (faces.length - 1) + 30,
                  height: 30,
                  child: Stack(
                    children: [
                      for (var i = 0; i < faces.length; i++)
                        Positioned(
                          left: 20.0 * i,
                          child: Container(
                            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.surface, width: 2)),
                            child: PersonAvatar(person: faces[i], size: 26, preview: false),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  '${total == 1 ? '1 vote' : '$total votes'} · $timeLeft left',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.mute, fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (selected != null)
                GestureDetector(
                  onTap: () => _changeVote(context),
                  child: Text('Change vote', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 14)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
