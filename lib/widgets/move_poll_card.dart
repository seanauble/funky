import 'package:flutter/material.dart';

import '../data/models.dart';
import 'avatar_preview.dart';
import 'ios_ui.dart';
import 'ui_widgets.dart';

/// "What's the move tonight?" on Home: compact rows — each spot's picture,
/// its name (up to two lines), a thin bar and its share of the vote in a
/// right-aligned column — split by thin lines. Your pick gets a small check
/// on its picture. Who voted and how long is left along the bottom.
class MovePollCard extends StatelessWidget {
  final List<String> labels;
  final List<int> counts;
  final int? selected;
  final ValueChanged<int> onSelect;
  final List<Person> voters;
  final String timeLeft;
  // Each option's picture (the venue's cover photo); null falls back to its
  // initials, or a couch for "Staying in".
  final List<Widget?> photos;

  const MovePollCard({
    super.key,
    required this.labels,
    required this.counts,
    required this.selected,
    required this.onSelect,
    required this.voters,
    required this.timeLeft,
    this.photos = const [],
  });

  static const _palette = [
    Color(0xFFC9692F), // orange
    Color(0xFF9B8AF0), // purple
    Color(0xFF4FA97A), // green
    Color(0xFFD966A8), // pink
    Color(0xFF4C8FE6), // blue
  ];

  static const double _photo = 46;
  // Room for "100%" on one line, lined up down the right side.
  static const double _pctWidth = 50;

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
      actions: [for (var i = 0; i < labels.length; i++) IosSheetAction(labels[i], i)],
    );
    if (picked != null) onSelect(picked);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final total = counts.fold<int>(0, (a, b) => a + b);

    Widget picture(int i) {
      final given = i < photos.length ? photos[i] : null;
      final staying = labels[i] == 'Staying in';
      final color = staying ? _palette.last : _palette[i % (_palette.length - 1)];
      final fallback = staying
          ? Container(
              color: tokens.raised,
              alignment: Alignment.center,
              child: Icon(Icons.weekend_rounded, color: tokens.mute, size: 22),
            )
          : Container(
              color: color,
              alignment: Alignment.center,
              child: Text(
                initials(labels[i]),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
              ),
            );
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(width: _photo, height: _photo, child: given ?? fallback),
      );
    }

    Widget row(int i) {
      final share = total == 0 ? 0.0 : counts[i] / total;
      final pct = (share * 100).round();
      final mine = selected == i;
      return InkWell(
        onTap: () => onSelect(i),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              // The picture, with a small check on your pick.
              SizedBox(
                width: _photo + 4,
                height: _photo + 4,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    picture(i),
                    if (mine)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 19,
                          height: 19,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: tokens.orange,
                            shape: BoxShape.circle,
                            border: Border.all(color: tokens.surface, width: 2),
                          ),
                          child: const Icon(Icons.check_rounded, color: Colors.white, size: 11),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels[i],
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15, height: 1.2),
                    ),
                    const SizedBox(height: 6),
                    // How much of the vote it has.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: SizedBox(
                        height: 4,
                        child: Stack(
                          children: [
                            Positioned.fill(child: ColoredBox(color: tokens.line.withValues(alpha: 0.5))),
                            FractionallySizedBox(
                              widthFactor: counts[i] == 0 ? 0 : share.clamp(0.04, 1.0),
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: mine ? tokens.orange : tokens.orange.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Fixed, right-aligned column so the numbers line up; "100%"
              // never wraps (it shrinks a touch before it would).
              SizedBox(
                width: _pctWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '$pct%',
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: mine ? tokens.orange : tokens.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: tokens.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: tokens.line.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "What's the move tonight?",
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 23, letterSpacing: -0.3),
            ),
            const SizedBox(height: 3),
            if (selected != null)
              Row(
                children: [
                  Text(
                    'Your vote is in',
                    style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 14.5),
                  ),
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
              Text(
                "Tap where you're headed",
                style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 14.5),
              ),
            const SizedBox(height: 6),
            for (var i = 0; i < labels.length; i++) ...[if (i > 0) Divider(height: 1, thickness: 0.5, indent: _photo + 14, color: tokens.line), row(i)],
            Divider(height: 1, thickness: 0.5, color: tokens.line),
            const SizedBox(height: 12),
            Row(
              children: [
                if (voters.isNotEmpty) ...[
                AvatarStack(people: voters, total: total, size: 26, ring: tokens.surface),
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
                    child: Text(
                      'Change vote',
                      style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
