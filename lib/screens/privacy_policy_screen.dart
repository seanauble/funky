import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

/// PLACEHOLDER legal copy — written to be directionally correct for what
/// FUNKY actually does (location, chat, Stories, local-only storage), but
/// this has NOT been reviewed by a lawyer. Apple requires a real, accurate
/// privacy policy URL in App Store Connect before you can submit for review
/// (FUNKY uses location, which gets extra scrutiny) — swap this out for
/// real legal copy before you ship.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'Privacy Policy',
      subtitle: 'Last updated: placeholder — replace with real legal copy before App Store submission.',
      sections: [
        InfoSection(
          'What we collect',
          'Your device location (used only to show you places, polls, and chat within the area you choose — 10 miles by default, up to 50; '
              'next to your Live Chat messages other people see only a rough "under N miles away", never your exact spot), '
              'a screen name and optional bio you choose, any Stories, poll votes, chat messages, and place '
              'reports you post, and basic device information needed to run the app.',
        ),
        InfoSection(
          'How it\'s used',
          'Location is used locally to rank nearby places and filter what you see — it is not sold or shared '
              'with advertisers. Stories, chat messages, and votes are shown to other nearby users as described '
              'in the app (anonymous mode hides your name). Friends can see your past Stories on your profile; '
              'nobody else can.',
        ),
        InfoSection(
          'Notifications',
          'If you allow notifications, your phone\'s push token is stored with your account so we can alert you '
              'about new messages, friend requests, new verified places near you, and reports at places you\'re '
              'going to. To work out which places are near you, your approximate location from when you last '
              'opened the app is kept privately on your account (no one else can see it). Turn any kind off in '
              'Settings; turning off new-place alerts removes the stored location.',
        ),
        InfoSection(
          'What gets deleted',
          'Most activity — chat, Stories, poll votes, place reports, who\'s "going" where — is wiped every day '
              'at 2 PM, by design. Your screen name, bio, points, and friends list are not wiped.',
        ),
        InfoSection(
          'Your choices',
          'You can turn on anonymous mode at any time, remove a friend, and deny location access (the app will '
              'ask you to enable it again to use most features). To request your data be deleted, contact us '
              'using the information below.',
        ),
        InfoSection(
          'Contact',
          'Questions about this policy can be sent to the app\'s support contact listed on its App Store page.',
        ),
      ],
    );
  }
}
