import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../theme/theme_provider.dart';
import '../widgets/ui_widgets.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'admin_panel_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_screen.dart';

/// Reached from the gear icon on Profile. Appearance used to just sit in
/// the middle of the profile page — it lives here now along with the
/// legal/about pages, like a normal app's settings screen.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final themeProvider = context.watch<ThemeProvider>();
    final store = context.watch<AppStore>();

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const SectionHeader(title: 'Account'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              label: store.signedIn ? 'Manage account (${store.accountEmail})' : 'Create an account to post & message',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
            ),
          ),
          if (store.signedIn) ...[
            const SectionHeader(title: 'Notifications'),
            FunkyCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _SwitchRow(label: 'Direct messages', value: store.notifPrefs.dm, onChanged: (v) => store.setNotifPref('dm', v)),
                  Divider(height: 1, color: tokens.line),
                  _SwitchRow(label: 'Friend requests', value: store.notifPrefs.friend, onChanged: (v) => store.setNotifPref('friend', v)),
                  Divider(height: 1, color: tokens.line),
                  _SwitchRow(label: 'New verified places near me', value: store.notifPrefs.place, onChanged: (v) => store.setNotifPref('place', v)),
                  Divider(height: 1, color: tokens.line),
                  _SwitchRow(label: 'Reports at places I\'m going to', value: store.notifPrefs.report, onChanged: (v) => store.setNotifPref('report', v)),
                ],
              ),
            ),
          ],
          const SectionHeader(title: 'Appearance'),
          Container(
            padding: const EdgeInsets.all(3),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: ThemePreference.values.map((opt) {
                final active = themeProvider.preference == opt;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => themeProvider.setPreference(opt),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(color: active ? tokens.surface : null, borderRadius: BorderRadius.circular(8)),
                      alignment: Alignment.center,
                      child: Text(
                        opt.name[0].toUpperCase() + opt.name.substring(1),
                        style: TextStyle(color: active ? tokens.ink : tokens.mute, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SectionHeader(title: 'Legal'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  label: 'Privacy Policy',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen())),
                ),
                Divider(height: 1, color: tokens.line),
                _SettingsRow(
                  label: 'Terms & Conditions',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TermsScreen())),
                ),
              ],
            ),
          ),
          const SectionHeader(title: 'About'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              label: 'About FUNKY',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
            ),
          ),
          // Only the one hardcoded FUNKY Admin account (store.isAdmin —
          // see app_store.dart) ever sees this section.
          if (store.isAdmin) ...[
            const SectionHeader(title: 'FUNKY Admin'),
            FunkyCard(
              padding: EdgeInsets.zero,
              child: _SettingsRow(
                label: 'Admin panel',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminPanelScreen())),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SettingsRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
            Text('›', style: TextStyle(color: tokens.mute)),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
          Switch(value: value, activeColor: tokens.brand, onChanged: onChanged),
        ],
      ),
    );
  }
}
