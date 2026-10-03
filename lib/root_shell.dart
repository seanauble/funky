import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';
import 'screens/create_sheet.dart';
import 'screens/home_screen.dart';
import 'screens/places_screen.dart';
import 'screens/profile_screen.dart';
import 'widgets/ui_widgets.dart';

/// The five-tab bar from rule 12 — Home, Chat, a centre "+" that opens the
/// Story/Poll/Place sheet, Places, Profile.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _screens = [
    HomeScreen(),
    ChatScreen(),
    SizedBox.shrink(), // center "+" slot — never actually shown
    PlacesScreen(),
    ProfileScreen(),
  ];

  static const _titles = ['Home', 'Chat', '', 'Places', 'Profile'];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: _index == 1 || _index == 3 || _index == 4
          ? null
          : AppBar(
              backgroundColor: tokens.bg,
              elevation: 0,
              title: Text(_titles[_index], style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
            ),
      body: SafeArea(bottom: false, child: IndexedStack(index: _index, children: _screens)),
      bottomNavigationBar: _TabBar(
        index: _index,
        onTap: (i) {
          if (i == 2) {
            showCreateSheet(context);
            return;
          }
          setState(() => _index = i);
        },
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _TabBar({required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      height: 60,
      decoration: BoxDecoration(color: tokens.glass, border: Border(top: BorderSide(color: tokens.line))),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _TabItem(icon: Icons.home, label: 'Home', active: index == 0, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(0)),
            _TabItem(icon: Icons.chat_bubble, label: 'Chat', active: index == 1, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(1)),
            Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: () => onTap(2),
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: tokens.brand,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: tokens.brand.withValues(alpha: 0.45), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: const Icon(Icons.add, color: Colors.white, size: 26),
                  ),
                ),
              ),
            ),
            _TabItem(icon: Icons.location_on, label: 'Places', active: index == 3, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(3)),
            _TabItem(icon: Icons.person, label: 'Profile', active: index == 4, color: tokens.orange, mute: tokens.mute, onTap: () => onTap(4)),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color color;
  final Color mute;
  final VoidCallback onTap;
  const _TabItem({required this.icon, required this.label, required this.active, required this.color, required this.mute, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? color : mute, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: active ? color : mute, fontSize: 10.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
