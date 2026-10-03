import 'package:flutter/material.dart';
import '../theme/colors.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
        ],
      ),
    );
  }
}

class FunkyChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onPressed;
  const FunkyChip({super.key, required this.label, this.active = false, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active ? tokens.brand : tokens.raised,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: active ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
    );
  }
}

class FunkyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  const FunkyCard({super.key, required this.child, this.padding, this.margin});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: TextStyle(color: tokens.mute)),
    );
  }
}

class FootNote extends StatelessWidget {
  final String text;
  const FootNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: tokens.line))),
      child: Text(text, style: TextStyle(color: tokens.mute, fontSize: 13)),
    );
  }
}

class FunkyAvatar extends StatelessWidget {
  final String seed;
  final String label;
  final double size;
  const FunkyAvatar({super.key, required this.seed, required this.label, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final color = hueOf(seed);
    final letter = label.isNotEmpty ? label.substring(0, 1).toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(letter, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.4)),
    );
  }
}

class FunkyHandle extends StatelessWidget {
  final String handle;
  const FunkyHandle({super.key, required this.handle});

  @override
  Widget build(BuildContext context) {
    final color = hueOf(handle);
    return Text('@$handle', style: TextStyle(color: color, fontWeight: FontWeight.w700));
  }
}

/// One heading + paragraph pair on an InfoScreen (Privacy Policy, Terms,
/// About — anything that's just static text in Settings).
class InfoSection {
  final String heading;
  final String body;
  const InfoSection(this.heading, this.body);
}

/// A plain scrollable title + sections page, shared by the static Settings
/// screens (Privacy Policy, Terms & Conditions, About) so they all look and
/// scroll the same way.
class InfoScreen extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<InfoSection> sections;
  const InfoScreen({super.key, required this.title, this.subtitle, required this.sections});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (subtitle != null) ...[
            Text(subtitle!, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
            const SizedBox(height: 18),
          ],
          for (final s in sections) ...[
            Text(s.heading, style: TextStyle(color: tokens.ink, fontSize: 15.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(s.body, style: TextStyle(color: tokens.mute, fontSize: 14, height: 1.45)),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}

/// A ThemeExtension wrapper so every widget can reach FUNKY's own color
/// tokens (ported straight from the prototype's CSS) through the normal
/// Theme.of(context) lookup, instead of plumbing them through as params.
class FunkyTokens extends ThemeExtension<FunkyTokens> {
  final ThemeTokens tokens;
  const FunkyTokens(this.tokens);

  @override
  FunkyTokens copyWith({ThemeTokens? tokens}) => FunkyTokens(tokens ?? this.tokens);

  @override
  FunkyTokens lerp(ThemeExtension<FunkyTokens>? other, double t) => this;
}
