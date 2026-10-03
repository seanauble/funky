import 'package:flutter/material.dart';
import 'ui_widgets.dart';

enum CreateKind { story, poll, place }

/// The prototype reuses one sheet for Story, Poll, and Place (rule 6 /
/// HANDOFF "Sheets"). Here that's one screen (CreateSheet) with this
/// picker switching internal state, which is actually closer to "one
/// reused sheet" than three separate routes would be.
class KindPicker extends StatelessWidget {
  final CreateKind active;
  final ValueChanged<CreateKind> onChanged;
  const KindPicker({super.key, required this.active, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    const kinds = [
      (CreateKind.story, 'Story'),
      (CreateKind.poll, 'Poll'),
      (CreateKind.place, 'Place'),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: kinds.map((k) {
          final isActive = k.$1 == active;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(k.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isActive ? Border.all(color: tokens.ink, width: 1.5) : null,
                ),
                alignment: Alignment.center,
                child: Text(k.$2, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
