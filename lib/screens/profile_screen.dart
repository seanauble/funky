import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../theme/theme_provider.dart';
import '../widgets/ui_widgets.dart';
import 'memories_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _handleController;
  late TextEditingController _bioController;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _handleController = TextEditingController(text: store.me.handle);
    _bioController = TextEditingController(text: store.me.bio);
  }

  @override
  void dispose() {
    _handleController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final themeProvider = context.watch<ThemeProvider>();

    const friends = 0; // mutual follows — real once DMs/friends are wired to a backend
    final following = store.me.following.length;
    const followers = 0;

    return Container(
      color: tokens.bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Column(
            children: [
              FunkyAvatar(seed: store.me.id, label: store.me.handle.isNotEmpty ? store.me.handle : '?', size: 88),
              TextField(
                controller: _handleController,
                onChanged: store.setHandle,
                textAlign: TextAlign.center,
                decoration: InputDecoration(hintText: 'Pick a screen name', hintStyle: TextStyle(color: tokens.mute), border: InputBorder.none),
                style: TextStyle(color: tokens.ink, fontSize: 20, fontWeight: FontWeight.w800),
              ),
              TextField(
                controller: _bioController,
                onChanged: store.setBio,
                textAlign: TextAlign.center,
                decoration: InputDecoration(hintText: 'Add a bio', hintStyle: TextStyle(color: tokens.mute), border: InputBorder.none),
                style: TextStyle(color: tokens.mute, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(label: 'Funky Points', value: store.me.points),
              _Stat(label: 'Friends', value: friends),
              _Stat(label: 'Following', value: following),
              _Stat(label: 'Followers', value: followers),
            ],
          ),
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MemoriesScreen())),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Memories', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  Text('›', style: TextStyle(color: tokens.mute)),
                ],
              ),
            ),
          ),
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
          const SectionHeader(title: 'Privacy'),
          FunkyCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Anonymous mode', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Hides your name and profile on chat and Stories.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ],
                  ),
                ),
                Switch(value: store.me.anon, onChanged: (_) {}, activeTrackColor: tokens.brand),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Expanded(
      child: Column(
        children: [
          Text('$value', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 20)),
          Text(label, style: TextStyle(color: tokens.mute, fontSize: 12)),
        ],
      ),
    );
  }
}
