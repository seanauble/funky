import 'package:flutter/material.dart';
import '../widgets/ui_widgets.dart';

// Keep _appVersion's leading number in sync with the `version:` line in
// pubspec.yaml by hand — we're deliberately not pulling in package_info_plus
// just to read it back, since every extra dependency is one more thing that
// can break the iOS build. _appBuild tracks the `+N` build number on that
// same line — Apple requires every TestFlight upload to carry a higher one
// than the last, so it still climbs every release, but it's just for our
// own reference now (e.g. telling two TestFlight installs apart) — it's no
// longer shown on this screen, which just says "Version 2" plainly instead
// of "Version 1.0.0 (25)".
const _appVersion = '3.0';
const _appBuild = '79';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoScreen(
      title: 'About',
      sections: [
        InfoSection('FUNKY', 'Version $_appVersion'),
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
