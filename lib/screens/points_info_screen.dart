import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
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
          Text('Customize your name', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Everything below is unlocked by points and stays unlocked forever — mix and match whatever you\'ve got.',
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          FunkyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Which title shows next to your name', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13.5)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TitleChip(
                      label: 'Auto (highest)',
                      selected: store.me.displayedTitleThreshold == null,
                      onTap: () => store.setDisplayedTitle(null),
                      tokens: tokens,
                    ),
                    ...store.myUnlockedTitles.map((t) => _TitleChip(
                          label: '${t.emoji} ${t.title}',
                          selected: store.me.displayedTitleThreshold == t.threshold,
                          onTap: () => store.setDisplayedTitle(t),
                          tokens: tokens,
                        )),
                  ],
                ),
                if (store.myUnlockedTitles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Earn 500 points to pick your first title.', style: TextStyle(color: tokens.mute, fontSize: 12)),
                  ),
                const Divider(height: 26),
                Text('Name styling', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13.5)),
                const SizedBox(height: 2),
                _NameStyleRow(
                  label: 'Bold name',
                  requiredPoints: 500,
                  unlocked: canUseBoldName(store.me.points),
                  value: store.me.nameBold,
                  onChanged: (v) => store.setNameStyle(bold: v),
                  tokens: tokens,
                ),
                _NameStyleRow(
                  label: 'Italic name',
                  requiredPoints: 1000,
                  unlocked: canUseItalicName(store.me.points),
                  value: store.me.nameItalic,
                  onChanged: (v) => store.setNameStyle(italic: v),
                  tokens: tokens,
                ),
                _NameStyleRow(
                  label: 'Underlined name',
                  requiredPoints: 2000,
                  unlocked: canUseUnderlineName(store.me.points),
                  value: store.me.nameUnderline,
                  onChanged: (v) => store.setNameStyle(underline: v),
                  tokens: tokens,
                ),
                _NameStyleRow(
                  label: 'Checkmark badge',
                  requiredPoints: 5000,
                  unlocked: canUseCheckName(store.me.points),
                  value: store.me.nameCheckbox,
                  onChanged: (v) => store.setNameStyle(checkbox: v),
                  tokens: tokens,
                ),
                const Divider(height: 26),
                Text('Name color', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13.5)),
                const SizedBox(height: 6),
                _NameColorPicker(tokens: tokens),
                const SizedBox(height: 14),
                Text('Preview', style: TextStyle(color: tokens.mute, fontSize: 11.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                StyledName(
                  person: store.me,
                  text: '@${store.me.handle.isNotEmpty ? store.me.handle : 'you'}',
                  style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 17),
                ),
              ],
            ),
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

/// One selectable pill in the "which title shows next to your name" picker.
class _TitleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ThemeTokens tokens;
  const _TitleChip({required this.label, required this.selected, required this.onTap, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? tokens.brand : tokens.raised,
          borderRadius: BorderRadius.circular(999),
          border: selected ? null : Border.all(color: tokens.line),
        ),
        child: Text(
          label,
          style: TextStyle(color: selected ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
    );
  }
}

/// One row of the name-styling toggles — greyed out and locked until
/// [requiredPoints], then a plain on/off switch once unlocked.
class _NameStyleRow extends StatelessWidget {
  final String label;
  final int requiredPoints;
  final bool unlocked;
  final bool value;
  final ValueChanged<bool> onChanged;
  final ThemeTokens tokens;
  const _NameStyleRow({
    required this.label,
    required this.requiredPoints,
    required this.unlocked,
    required this.value,
    required this.onChanged,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              unlocked ? label : '$label — needs $requiredPoints pts',
              style: TextStyle(color: unlocked ? tokens.ink : tokens.mute, fontWeight: unlocked ? FontWeight.w600 : FontWeight.w500),
            ),
          ),
          if (unlocked)
            Switch(value: value, onChanged: onChanged, activeColor: tokens.brand)
          else
            Icon(Icons.lock_outline, size: 18, color: tokens.mute),
        ],
      ),
    );
  }
}

/// The name color selector — a row of preset swatches plus hue/saturation/
/// brightness sliders for any color you like. Locked until
/// [nameColorUnlockPoints], same as every other name style; once unlocked
/// the color you land on is saved when you let go of a slider (not on
/// every pixel of the drag), and shows up on your name everywhere.
class _NameColorPicker extends StatefulWidget {
  final ThemeTokens tokens;
  const _NameColorPicker({required this.tokens});

  @override
  State<_NameColorPicker> createState() => _NameColorPickerState();
}

class _NameColorPickerState extends State<_NameColorPicker> {
  HSVColor? _hsv;

  static const _presets = [
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C7BE),
    Color(0xFF32ADE6),
    Color(0xFF5E5CE6),
    Color(0xFFAF52DE),
    Color(0xFFFF2D92),
    Color(0xFFFFFFFF),
    Color(0xFF8E8E93),
    Color(0xFF000000),
  ];

  void _commit(AppStore store) {
    final hsv = _hsv;
    if (hsv == null) return;
    store.setNameColor(hsv.toColor().toARGB32());
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged, AppStore store) {
    final tokens = widget.tokens;
    return Row(
      children: [
        SizedBox(width: 30, child: Text(label, style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w700))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            activeColor: tokens.brand,
            onChanged: onChanged,
            onChangeEnd: (_) => _commit(store),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final store = context.watch<AppStore>();
    final unlocked = canUseNameColor(store.me.points);
    if (!unlocked) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Pick any color for your name — needs $nameColorUnlockPoints pts',
                style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.lock_outline, size: 18, color: tokens.mute),
          ],
        ),
      );
    }
    final current = store.me.nameColor;
    final hsv = _hsv ?? HSVColor.fromColor(Color(current ?? 0xFFFF7A1A));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            GestureDetector(
              onTap: () {
                setState(() => _hsv = null);
                store.setNameColor(null);
              },
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tokens.raised,
                  border: Border.all(color: current == null ? tokens.brand : tokens.line, width: current == null ? 2.5 : 1),
                ),
                child: Icon(Icons.block, size: 16, color: tokens.mute),
              ),
            ),
            ..._presets.map((c) {
              final selected = current == c.toARGB32();
              return GestureDetector(
                onTap: () {
                  setState(() => _hsv = HSVColor.fromColor(c));
                  store.setNameColor(c.toARGB32());
                },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c,
                    border: Border.all(color: selected ? tokens.brand : tokens.line, width: selected ? 3 : 1),
                  ),
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 8),
        _slider('Hue', hsv.hue, 0, 359.9, (v) => setState(() => _hsv = hsv.withHue(v)), store),
        _slider('Sat', hsv.saturation, 0, 1, (v) => setState(() => _hsv = hsv.withSaturation(v)), store),
        _slider('Lite', hsv.value, 0, 1, (v) => setState(() => _hsv = hsv.withValue(v)), store),
      ],
    );
  }
}
