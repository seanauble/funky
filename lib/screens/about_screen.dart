import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

// Keep this in sync with the `version:` line in pubspec.yaml by hand — we're
// deliberately not pulling in package_info_plus just to read it back, since
// every extra dependency is one more thing that can break the iOS build.
const _appVersion = '1.0.0';
const _appBuild = '7';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'About',
      sections: [
        InfoSection('FUNKY', 'Version $_appVersion ($_appBuild)'),
        InfoSection(
          'What it is',
          'FUNKY shows you what\'s happening within 25 miles of you right now — places, polls, live chat, and '
              'Stories — and clears most of it every day at 2 PM so it always feels like tonight, not a feed '
              'of old posts.',
        ),
        InfoSection(
          'Made by',
          'Built by the FUNKY team.',
        ),
      ],
    );
  }
}
