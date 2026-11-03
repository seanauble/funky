import 'package:flutter/material.dart';
import '../data/models.dart';
import '../screens/person_profile_screen.dart';
import '../screens/profile_screen.dart';
import 'ui_widgets.dart';

/// Opens somebody's profile — your own full Profile page when [personId] is
/// 'me' (wrapped in its own Scaffold + back arrow, since on the Profile tab
/// itself that page relies on the root shell's AppBar and has none of its
/// own), otherwise their public PersonProfileScreen.
void openProfile(BuildContext context, String personId) {
  if (personId == 'me') {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('My profile')),
        body: const ProfileScreen(),
      ),
    ));
  } else {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: personId)));
  }
}

/// The big preview that pops up when you tap anybody's profile picture —
/// yours or someone else's — with a shortcut through to their full profile.
Future<void> showAvatarPreview(BuildContext context, Person person, {bool viewProfile = true}) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(dialogContext).pop(),
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white24, width: 2)),
              child: FunkyAvatar(
                seed: person.id,
                label: person.handle.isNotEmpty ? person.handle : '?',
                size: 260,
                photoPath: person.photoPath,
                photoUrl: person.photoUrl,
              ),
            ),
          ),
          const SizedBox(height: 14),
          StyledName(
            person: person,
            text: '@${person.handle}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20),
          ),
          if (person.bio.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(person.bio, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          if (viewProfile) ...[
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                openProfile(context, person.id);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              child: Text(person.id == 'me' ? 'View my profile' : 'View profile', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
            ),
          ],
        ],
      ),
    ),
  );
}

/// The 👻 circle shown in place of a profile picture on anonymous posts —
/// never reveals who it really is.
class GhostAvatar extends StatelessWidget {
  final double size;
  const GhostAvatar({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle),
      child: Text('👻', style: TextStyle(fontSize: size * 0.5)),
    );
  }
}

/// A person's profile picture. Tap it to go straight to their profile;
/// press and hold for the big picture preview. On a profile page itself
/// ([viewProfile] false) a tap shows the big preview instead, since there's
/// nowhere further to go.
class PersonAvatar extends StatelessWidget {
  final Person person;
  final double size;
  // false renders the plain picture with no tap handling (e.g. inside a row
  // that already navigates somewhere on tap).
  final bool preview;
  // Whether the preview offers a "View profile" button — off when the
  // picture is already sitting on that person's own profile page.
  final bool viewProfile;
  const PersonAvatar({super.key, required this.person, this.size = 28, this.preview = true, this.viewProfile = true});

  @override
  Widget build(BuildContext context) {
    final avatar = FunkyAvatar(
      seed: person.id,
      label: person.handle.isNotEmpty ? person.handle : '?',
      size: size,
      photoPath: person.photoPath,
      photoUrl: person.photoUrl,
    );
    if (!preview) return avatar;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => viewProfile ? openProfile(context, person.id) : showAvatarPreview(context, person, viewProfile: false),
      onLongPress: () => showAvatarPreview(context, person, viewProfile: viewProfile),
      child: avatar,
    );
  }
}

/// Who's going / who voted: exactly 3 overlapping faces once there are 3
/// or more people (fewer only when fewer exist), then a "+N" bubble for
/// everyone else. Pass [people] already in order (AppStore.faceOrder:
/// friends first, most popular first). With no [total] but [more] set,
/// the bubble is just "+" (when the host keeps the number hidden).
class AvatarStack extends StatelessWidget {
  final List<Person> people;
  final int? total;
  final bool more;
  final double size;
  // The ring around each face — the color behind the stack.
  final Color? ring;
  const AvatarStack({super.key, required this.people, this.total, this.more = false, this.size = 26, this.ring});

  static const maxFaces = 3;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final shown = people.take(maxFaces).toList();
    final all = total ?? people.length;
    final extra = all - shown.length;
    final bubble = extra > 0 || (total == null && more);
    final count = shown.length + (bubble ? 1 : 0);
    if (count == 0) return const SizedBox.shrink();
    final border = size >= 34 ? 2.0 : 1.5;
    final outer = size + border * 2;
    final step = size * 0.72;
    final ringColor = ring ?? tokens.surface;
    final label = extra > 0 ? (extra > 99 ? '99+' : '+$extra') : '+';
    return SizedBox(
      width: step * (count - 1) + outer,
      height: outer,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: step * i,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ringColor, width: border)),
                child: PersonAvatar(person: shown[i], size: size, preview: false),
              ),
            ),
          if (bubble)
            Positioned(
              left: step * shown.length,
              child: Container(
                width: outer,
                height: outer,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tokens.raised,
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor, width: border),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: size * 0.4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
