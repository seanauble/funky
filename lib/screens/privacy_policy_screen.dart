import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

/// FUNKY's Privacy Policy (the same text is in docs/privacy.html for the web,
/// which is the link that goes in App Store Connect). Written to match what
/// the app actually does; not reviewed by a lawyer.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'Privacy Policy',
      subtitle: 'Last updated November 1, 2026',
      sections: [
        InfoSection(
          'What we collect',
          '• Account: your email address and password (handled by our backend provider), your @username, bio and profile photo.\n'
              '• Location: your phone\'s location while you use the app, to show what\'s happening within the radius you choose.\n'
              '• What you post: stories, posts, photos and videos, comments, events, live chat, polls, messages, ratings and reports.\n'
              '• Activity: likes, who you follow as friends, where you tap "I\'m going", and points.\n'
              '• Contacts (only if you use "Find friends from contacts"): email addresses in your contacts are turned into '
              'one-way scrambled codes on your phone and only those codes are checked against FUNKY accounts. Your contacts are never uploaded or saved.\n'
              '• Device: your push notification token, and error reports (what went wrong in the app and the app version) so we can fix bugs.',
        ),
        InfoSection(
          'Who sees what',
          '• Your exact location is never shown to anyone. Stories and posts only show a location if you tag a place.\n'
              '• Posts, events and stories are visible to people whose area includes where you posted them.\n'
              '• Older stories (memories) are visible only to your friends. Anonymous stories and chat never show your name.\n'
              '• Messages are visible only to the people in the conversation.',
        ),
        InfoSection(
          'How we use it',
          'Only to run FUNKY: showing nearby places, posts and chat, sending notifications you\'ve allowed, keeping '
              'the app safe (reviewing reports, removing content, banning abusive users) and fixing bugs. We don\'t '
              'sell your data, we don\'t show ads, and we don\'t share your data with advertisers or data brokers.',
        ),
        InfoSection(
          'Service providers',
          'Data is stored with Supabase (database, login and file storage). Push notifications go through Apple. '
              'Video calls use LiveKit. Map tiles and address lookups come from OpenStreetMap services. These '
              'providers only process data to provide their service to FUNKY.',
        ),
        InfoSection(
          'How long we keep it',
          'Live chat, stories and polls reset daily (stories you keep become memories). Your account data stays until '
              'you delete your account. Error reports are deleted after 30 days.',
        ),
        InfoSection(
          'Your choices',
          '• Delete your account and everything you posted any time: Settings → Delete my account.\n'
              '• Turn off location, contacts or notifications in your iPhone\'s Settings.\n'
              '• Block or report anyone from their profile.',
        ),
        InfoSection(
          'Age',
          'FUNKY is only for people 21 and older. We don\'t knowingly collect data from anyone younger and delete it if we find out.',
        ),
        InfoSection(
          'Contact',
          'Questions or requests: seanauble@icloud.com.',
        ),
      ],
    );
  }
}
