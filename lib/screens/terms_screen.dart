import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

/// FUNKY's Terms of Use (the same text is in docs/terms.html for the web).
/// Includes the zero-tolerance rules Apple requires for apps where people
/// post content (App Review Guideline 1.2). Not reviewed by a lawyer — worth
/// having one look before a big launch.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'Terms of Use',
      subtitle: 'Last updated November 1, 2026',
      sections: [
        InfoSection(
          'Agreeing to these terms',
          'By creating an account or using FUNKY you agree to these Terms and to our Privacy Policy. If you don\'t '
              'agree, don\'t use the app.',
        ),
        InfoSection(
          'You must be 21 or older',
          'FUNKY is about bars, clubs, parties and going out, so it is only for people 21 and older. By using it you '
              'confirm you are at least 21. Accounts we believe belong to someone under 21 will be removed.',
        ),
        InfoSection(
          'Zero tolerance for objectionable content and abusive users',
          'There is no tolerance on FUNKY for objectionable content or abusive behavior. You may not post, send or '
              'share anything that is: harassment, bullying, threats or hate speech; sexually explicit or nude '
              'content; violent, graphic or self-harm content; content that sells or promotes illegal drugs or other '
              'illegal activity; spam, scams or impersonation; or someone else\'s private information (including '
              'where they live) or photos of people who didn\'t agree to be posted.\n\n'
              'Content that breaks these rules is removed, and people who post it or who abuse others are banned. '
              'This applies to stories, posts, comments, events, live chat, polls, messages, profile photos and names.',
        ),
        InfoSection(
          'Reporting and blocking',
          'You can report any story, post, profile or message with the flag or "Report" option, and block anyone '
              'from their profile. Blocked people can\'t message you, friend you or comment on your posts. We review '
              'every report and act on objectionable content within 24 hours, including removing it and banning the '
              'person who posted it.',
        ),
        InfoSection(
          'Your content',
          'You own what you post, and you\'re responsible for it. By posting, you let FUNKY show it to other people '
              'in the app as described (for example, posts are visible to everyone nearby). We may remove anything '
              'that breaks these Terms or makes the app unsafe.',
        ),
        InfoSection(
          'Drink responsibly, get home safe',
          'FUNKY never encourages drinking. Don\'t drink and drive, don\'t use FUNKY while driving, and look out for '
              'your friends. Information about places, covers, lines, police activity and events is posted by users '
              'and may be wrong; use your own judgment.',
        ),
        InfoSection(
          'Points and rewards',
          'Funky Points, levels and badges are just for fun. They have no cash value and can\'t be sold or traded. '
              'We may adjust points that were earned by breaking the rules or gaming the app.',
        ),
        InfoSection(
          'Deleting your account',
          'You can delete your account any time in Settings → Delete my account. That removes your profile and '
              'everything you posted.',
        ),
        InfoSection(
          'Ending access',
          'We may suspend or ban accounts that break these Terms, without notice.',
        ),
        InfoSection(
          'No guarantees',
          'FUNKY is provided "as is". We aren\'t responsible for what users post or for anything that happens at '
              'places or events listed in the app. To the extent the law allows, our liability is limited to the '
              'amount you paid us (FUNKY is free, so zero).',
        ),
        InfoSection(
          'Changes and contact',
          'We may update these Terms as FUNKY changes; continuing to use it means you accept the new version. '
              'Questions or reports: seanauble@icloud.com.',
        ),
      ],
    );
  }
}
