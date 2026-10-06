import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../screens/notifications_screen.dart';
import '../screens/settings_screen.dart';
import 'ui_widgets.dart';

/// The notifications bell with its live unread count — shared so it shows
/// up the same way on every main tab's AppBar (Home, Chat, Places,
/// Profile), not just Profile.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    // Unread notifications, plus any friend requests still waiting that
    // predate the notifications feature (so an old request still shows).
    final pending = store.unreadNotificationCount > 0 ? store.unreadNotificationCount : store.pendingFriendRequestCount;
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.notifications_none, color: tokens.ink),
          if (pending > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(3),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle, border: Border.all(color: tokens.bg, width: 1.5)),
                alignment: Alignment.center,
                child: Text(
                  pending > 99 ? '99+' : '$pending',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The gear that opens Settings — shared for the same reason as the bell.
class SettingsGearButton extends StatelessWidget {
  const SettingsGearButton({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return IconButton(
      tooltip: 'Settings',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      icon: Icon(Icons.settings_outlined, color: tokens.ink),
    );
  }
}
