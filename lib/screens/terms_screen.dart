import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

/// PLACEHOLDER legal copy — same caveat as privacy_policy_screen.dart: this
/// has NOT been reviewed by a lawyer. Replace before shipping to the App
/// Store, especially the age-and-alcohol-context language given what FUNKY
/// is used for.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'Terms & Conditions',
      subtitle: 'Last updated: placeholder — replace with real legal copy before App Store submission.',
      sections: [
        InfoSection(
          'Using FUNKY',
          'FUNKY helps you find out what\'s happening near you tonight and talk to people nearby. You agree to '
              'use it respectfully — no harassment, no posting other people\'s private information, and no '
              'using the app to plan or encourage anything illegal.',
        ),
        InfoSection(
          'Your content',
          'You\'re responsible for what you post — Stories, chat messages, place reports, and polls. We can '
              'remove content or suspend accounts that violate these terms or make the app unsafe for others.',
        ),
        InfoSection(
          'Age requirement',
          'FUNKY is intended for users old enough to use the venues and events referenced in the app under '
              'applicable local law. Don\'t use the app if you don\'t meet that requirement.',
        ),
        InfoSection(
          'No guarantees',
          'Place information, "going" counts, and reports (cover charges, police activity, closures) are '
              'posted by users and not verified by FUNKY — treat them as unofficial, and use your own judgment.',
        ),
        InfoSection(
          'Changes',
          'We may update these terms as the app changes. Continuing to use FUNKY after an update means you '
              'accept the revised terms.',
        ),
      ],
    );
  }
}
