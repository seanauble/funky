import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../services/share_links.dart';
import '../widgets/ui_widgets.dart';
import '../widgets/rainbow_wordmark.dart';
import 'account_screen.dart';
import 'contacts_friends_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_screen.dart';

/// The first-run walkthrough, shown once per phone before the app opens:
/// what FUNKY is, the 21+ check (with the Terms), location, notifications,
/// then finding friends and inviting people.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  bool _under21 = false;
  bool _busy = false;
  static const _count = 5;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= _count - 1) {
      context.read<AppStore>().completeOnboarding();
      return;
    }
    _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _next();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    Widget page({required IconData icon, required String title, required String body, required List<Widget> actions, Widget? extra}) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(26, 12, 26, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: tokens.orange.withValues(alpha: 0.14), shape: BoxShape.circle),
              child: Icon(icon, color: tokens.orange, size: 32),
            ),
            const SizedBox(height: 20),
            Text(title, style: TextStyle(color: tokens.ink, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),
            const SizedBox(height: 10),
            Text(body, style: TextStyle(color: tokens.mute, fontSize: 15.5, height: 1.4)),
            if (extra != null) ...[const SizedBox(height: 18), extra],
            const Spacer(flex: 2),
            ...actions,
          ],
        ),
      );
    }

    Widget primary(String label, VoidCallback? onTap) => SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.brand,
              disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(label, style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        );

    Widget secondary(String label, VoidCallback? onTap) => SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: onTap,
            child: Text(label, style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700)),
          ),
        );

    Widget feature(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(icon, color: tokens.orange, size: 22),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: TextStyle(color: tokens.ink, fontSize: 15, fontWeight: FontWeight.w600))),
            ],
          ),
        );

    final pages = <Widget>[
      // 1. What FUNKY is
      Padding(
        padding: const EdgeInsets.fromLTRB(26, 12, 26, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            const RainbowWordmark(height: 54),
            const SizedBox(height: 18),
            Text("See what's happening tonight, right around you.",
                style: TextStyle(color: tokens.ink, fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
            const SizedBox(height: 22),
            feature(Icons.auto_awesome_motion_rounded, 'Stories and posts from people in your area'),
            feature(Icons.local_fire_department_rounded, "Which bars, parties and events are busy"),
            feature(Icons.groups_rounded, 'Where your friends are headed'),
            feature(Icons.forum_rounded, 'Live chat with everyone nearby'),
            const Spacer(flex: 2),
            primary("Let's go", _next),
          ],
        ),
      ),
      // 2. 21+ and Terms
      page(
        icon: Icons.verified_user_outlined,
        title: 'Are you 21 or older?',
        body: 'FUNKY is about bars and going out, so it\'s only for people 21 and up.',
        extra: _under21
            ? Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(14)),
                child: Text(
                  "Sorry, you need to be 21 or older to use FUNKY. Come back on your 21st!",
                  style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600),
                ),
              )
            : Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('By continuing you agree to the ', style: TextStyle(color: tokens.mute, fontSize: 13)),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TermsScreen())),
                    child: Text('Terms', style: TextStyle(color: tokens.orange, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  Text(' and ', style: TextStyle(color: tokens.mute, fontSize: 13)),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen())),
                    child: Text('Privacy Policy', style: TextStyle(color: tokens.orange, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  Text('.', style: TextStyle(color: tokens.mute, fontSize: 13)),
                ],
              ),
        actions: [
          primary("I'm 21 or older", _under21 ? null : () => _run(() => store.confirmAgeAndTerms())),
          secondary("I'm under 21", () => setState(() => _under21 = true)),
        ],
      ),
      // 3. Location
      page(
        icon: Icons.location_on_rounded,
        title: 'Turn on location',
        body: 'FUNKY shows you places, stories, posts and chat from your area. Your exact spot is never shown to anyone.',
        actions: [
          primary('Turn on location', _busy ? null : () => _run(() => store.requestLocation())),
          secondary('Not now', _next),
        ],
      ),
      // 4. Notifications
      page(
        icon: Icons.notifications_active_rounded,
        title: 'Know when friends head out',
        body: 'Get a heads up when friends are going somewhere, someone messages you, or your post is popping.',
        actions: [
          primary('Turn on notifications', _busy ? null : () => _run(() async => store.requestNotifications())),
          secondary('Not now', _next),
        ],
      ),
      // 5. Friends
      page(
        icon: Icons.group_add_rounded,
        title: 'Bring your crew',
        body: store.signedIn
            ? 'Find friends who are already on FUNKY from your contacts, and invite everyone else.'
            : 'Make a free account to add friends, post and message. You can also just look around first.',
        actions: [
          if (store.signedIn)
            primary('Find friends from contacts', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContactsFriendsScreen())))
          else
            primary('Create an account', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen()))),
          const SizedBox(height: 6),
          Builder(
            builder: (c) => secondary('Invite friends', () => shareFunkyInvite(c, handle: store.signedIn ? store.me.handle : null)),
          ),
          secondary('Start exploring', _next),
        ],
      ),
    ];

    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  for (var i = 0; i < _count; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i <= _page ? tokens.orange : tokens.line,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                // Only the buttons move it along, so the 21+ check can't be
                // swiped past.
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: pages,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
