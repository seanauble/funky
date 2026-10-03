import 'package:flutter/material.dart';
import '../theme/colors.dart';
import 'ui_widgets.dart';

class PollBars extends StatelessWidget {
  final List<String> options;
  final List<int> counts;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  const PollBars({super.key, required this.options, required this.counts, this.selectedIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final total = counts.fold<int>(0, (a, b) => a + b);
    return Column(
      children: List.generate(options.length, (i) {
        final pct = total > 0 ? ((counts[i] / total) * 100).round() : 0;
        final widthPct = counts[i] > 0 ? (pct < 6 ? 6 : pct) : 0;
        final color = pollColors[i % pollColors.length];
        final selected = selectedIndex == i;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: tokens.track,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? tokens.ink : Colors.transparent, width: 1.5),
              ),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    child: FractionallySizedBox(
                      widthFactor: widthPct / 100,
                      alignment: Alignment.centerLeft,
                      child: Container(color: color.withValues(alpha: 0.35)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            options[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tokens.optionText, fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('$pct%', style: TextStyle(color: tokens.optionText, fontWeight: FontWeight.w700, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
