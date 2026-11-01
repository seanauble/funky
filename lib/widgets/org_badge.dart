import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/org_badges.dart';
import '../data/post_models.dart';

/// The fraternity/sorority letters (ΤΚΕ) or college short name (PSU) for a
/// party, event, tailgate or frat — see org_badges.dart.
OrgBadge? placeOrgBadge(Place place) => orgBadgeFor(place.name, kind: place.kind.name);

/// An event post's badge, from its title (or caption).
OrgBadge? postOrgBadge(Post post) {
  if (post.isEvent) return orgBadgeFor(post.eventTitle, kind: 'event') ?? detectGreek(post.caption);
  return detectGreek(post.caption);
}

/// A Story's badge: the place it was posted at, else Greek letters in its
/// caption.
OrgBadge? storyOrgBadge(AppStore store, Story story) {
  final placeId = story.place;
  if (placeId != null && placeId != 'main') {
    for (final p in store.places) {
      if (p.id == placeId) {
        final b = placeOrgBadge(p);
        if (b != null) return b;
        break;
      }
    }
  }
  final text = story.text;
  return text == null ? null : detectGreek(text);
}

double _luminance(Color c) => c.computeLuminance();

/// Letters on a little colored tag, in the organization's colors.
class OrgLettersBadge extends StatelessWidget {
  final OrgBadge badge;
  final bool small;
  const OrgLettersBadge({super.key, required this.badge, this.small = false});

  @override
  Widget build(BuildContext context) {
    final bg = Color(badge.bg);
    var fg = Color(badge.fg);
    // Too little contrast to read: fall back to white or black.
    final lb = _luminance(bg);
    final lf = _luminance(fg);
    final ratio = (lb > lf ? (lb + 0.05) / (lf + 0.05) : (lf + 0.05) / (lb + 0.05));
    if (ratio < 2.6) fg = lb > 0.45 ? Colors.black : Colors.white;
    final greek = badge.kind == OrgKind.greek;
    return Tooltip(
      message: badge.name,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 5 : 8, vertical: small ? 1.5 : 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(small ? 5 : 7),
          border: Border.all(color: fg.withValues(alpha: 0.55), width: small ? 1 : 1.4),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: Text(
          badge.letters,
          maxLines: 1,
          style: TextStyle(
            color: fg,
            fontSize: small ? (greek ? 10.5 : 9) : (greek ? 15 : 12),
            fontWeight: FontWeight.w900,
            letterSpacing: greek ? (small ? 0.6 : 1.2) : 0.4,
            height: 1.15,
            fontFamily: greek ? 'Times New Roman' : null,
            fontFamilyFallback: const ['Georgia', 'serif'],
          ),
        ),
      ),
    );
  }
}

/// [child] with [badge] pinned to its top-right corner (nothing if null).
class OrgBadgeCorner extends StatelessWidget {
  final Widget child;
  final OrgBadge? badge;
  final bool small;
  final double inset;
  const OrgBadgeCorner({super.key, required this.child, required this.badge, this.small = false, this.inset = 8});

  @override
  Widget build(BuildContext context) {
    final b = badge;
    if (b == null) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(top: inset, right: inset, child: OrgLettersBadge(badge: b, small: small)),
      ],
    );
  }
}
