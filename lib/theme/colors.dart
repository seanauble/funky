import 'package:flutter/material.dart';

/// Pulled directly from the web prototype's CSS custom properties
/// (index.html) so the native app matches it exactly instead of drifting to
/// generic Flutter defaults. Dark is FUNKY's primary look ("black with the
/// orange FUNKY logo"); light is the secondary mode from rule 11.
class ThemeTokens {
  final Color bg;
  final Color surface;
  final Color raised;
  final Color line;
  final Color ink;
  final Color mute;
  final Color orange;
  final Color brand;
  final Color onOrange;
  final Color track;
  final Color optionText;
  final Color map;
  final Color mapLine;
  final Color you;
  final Color gold;
  final Color glass;
  final Color shade;
  final Color danger;
  // Story-ring color for someone you're friends with — always this, never
  // the normal orange/gray unseen styling, so a friend's ring reads as
  // "someone you know" at a glance regardless of whether you've watched yet.
  final Color friend;

  const ThemeTokens({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.ink,
    required this.mute,
    required this.orange,
    required this.brand,
    required this.onOrange,
    required this.track,
    required this.optionText,
    required this.map,
    required this.mapLine,
    required this.you,
    required this.gold,
    required this.glass,
    required this.shade,
    required this.danger,
    required this.friend,
  });
}

const lightTokens = ThemeTokens(
  bg: Color(0xFFF5F5F7),
  surface: Color(0xFFFFFFFF),
  raised: Color(0xFFE8E8ED),
  line: Color(0xFFD9D9E0),
  ink: Color(0xFF111114),
  mute: Color(0xFF676772),
  orange: Color(0xFFE05600),
  brand: Color(0xFFFC6401),
  onOrange: Color(0xFFFFFFFF),
  track: Color(0xFFE8E8ED),
  optionText: Color(0xFF111114),
  map: Color(0xFFE4E4EA),
  mapLine: Color(0xFFCACAD3),
  you: Color(0xFF0A84FF),
  gold: Color(0xFFB87A00),
  glass: Color(0xCCF5F5F7),
  shade: Color(0x730A0A0E),
  danger: Color(0xFFE0353C),
  friend: Color(0xFF1F9D55),
);

const darkTokens = ThemeTokens(
  bg: Color(0xFF0A0A0C),
  surface: Color(0xFF17171B),
  raised: Color(0xFF232329),
  line: Color(0xFF2E2E36),
  ink: Color(0xFFFFFFFF),
  mute: Color(0xFF9B9BA7),
  orange: Color(0xFFFF7A1A),
  brand: Color(0xFFFC6401),
  onOrange: Color(0xFFFFFFFF),
  track: Color(0xFF1E1E23),
  optionText: Color(0xFFFFFFFF),
  map: Color(0xFF16161D),
  mapLine: Color(0xFF34343F),
  you: Color(0xFF3B9BFF),
  gold: Color(0xFFFFC247),
  glass: Color(0xC70A0A0C),
  shade: Color(0x99000000),
  danger: Color(0xFFE0353C),
  friend: Color(0xFF34D17A),
);

/// The "orange to pink to purple" poll-bar gradient (PCOL in the
/// prototype), cycled by option index so a poll with more options just
/// keeps going.
const List<Color> pollColors = [
  Color(0xFFFC6401), // orange (brand)
  Color(0xFFE0357B), // pink
  Color(0xFFB03AC8), // magenta
  Color(0xFF7B3FE4), // purple
  Color(0xFF5646D8), // indigo
  Color(0xFF3D4FC9), // blue-indigo
  Color(0xFF2779CC), // blue
  Color(0xFF0C8C76), // teal
];

/// Story-ring / handle hue classes (c0..c5 in the prototype), used to give
/// each person's @handle a consistent, distinct color without avatars.
const List<Color> handleColors = [
  Color(0xFFE0457B),
  Color(0xFF8A70FF),
  Color(0xFF0E9F86),
  Color(0xFFFF7A1A),
  Color(0xFF2F8FE8),
  Color(0xFFB87A00),
];

Color hueOf(String seed) {
  var h = 0;
  for (final code in seed.codeUnits) {
    h = (h * 31 + code) & 0x7fffffff;
  }
  return handleColors[h % handleColors.length];
}
