import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';

/// FUNKY Admin tools for one account — points, ban, admin access — kept on
/// their own screen instead of mixed into the person's profile. Opened from
/// "Manage this account (Admin)" on someone's profile, or "Admin tools" on
/// your own (where only the points controls apply).
class AdminManageUserScreen extends StatelessWidget {
  /// A user id, or 'me' for your own account.
  final String personId;
  const AdminManageUserScreen({super.key, required this.personId});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(personId);
    final self = personId == 'me';

    if (!store.isAdmin || person == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Manage account')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(store.isAdmin ? "That account isn't loaded." : 'Admins only.', style: TextStyle(color: tokens.mute)),
        ),
      );
    }
    final banned = !self && store.isBanned(personId);

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Text(self ? 'Admin tools' : 'Manage @${person.handle}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          FunkyCard(
            child: Row(
              children: [
                PersonAvatar(person: person, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(self ? 'Your account' : '@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(
                        '${person.points} pts'
                        '${person.isAdminUser || self ? ' · Admin' : ''}'
                        '${banned ? ' · Banned' : ''}',
                        style: TextStyle(color: banned ? tokens.danger : tokens.mute, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader(title: 'Points'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final amount in const [100, 500, 1000, -100, -500, -1000])
                OutlinedButton(
                  onPressed: () => _givePoints(context, store, personId, person.handle, amount),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: tokens.gold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(amount > 0 ? '+$amount pts' : '$amount pts', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800)),
                ),
              OutlinedButton.icon(
                onPressed: () => _customPoints(context, store, personId, person.handle),
                icon: Icon(Icons.tune, size: 16, color: tokens.gold),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: tokens.gold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                label: Text('Custom', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          if (self) ...[
            const SizedBox(height: 18),
            Text('As an admin you can change your username any time.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
          ],
          if (!self) ...[
            const SectionHeader(title: 'Account'),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => banned ? store.unbanUser(personId) : _confirmBan(context, store, personId, person.handle),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: tokens.danger),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(banned ? Icons.lock_open : Icons.block, size: 18, color: tokens.danger),
                label: Text(banned ? 'Unban user' : 'Ban user', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
              ),
            ),
            // Only the owner can hand out (or take back) admin access.
            if (store.isOwner) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final makeAdmin = !person.isAdminUser;
                    final error = await store.adminSetAdmin(personId, makeAdmin);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(error ?? (makeAdmin ? '@${person.handle} is now an admin.' : '@${person.handle} is no longer an admin.')),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: tokens.gold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: Icon(person.isAdminUser ? Icons.shield_outlined : Icons.shield, size: 18, color: tokens.gold),
                  label: Text(
                    person.isAdminUser ? 'Remove admin access' : 'Make admin',
                    style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// A confirmation before banning — this severs an existing friendship or
/// pending request and hides the person's Stories/chat/DMs everywhere.
Future<void> _confirmBan(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.surface,
      title: Text('Ban @$handle?', style: TextStyle(color: tokens.ink)),
      content: Text(
        "This unfriends them if you're friends, and hides their Stories, chat messages, and DMs from everyone.",
        style: TextStyle(color: tokens.mute),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Ban', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (confirmed == true) store.banUser(personId);
}

/// Gives (or takes away) points and says how it went.
Future<void> _givePoints(BuildContext context, AppStore store, String personId, String handle, int amount) async {
  final error = await store.adminGivePoints(personId, amount);
  if (!context.mounted) return;
  final who = personId == 'me' ? 'yourself' : '@$handle';
  final text = amount > 0 ? 'Gave $who +$amount points.' : 'Removed ${-amount} points from $who.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? text), duration: const Duration(seconds: 1)));
}

/// Type any amount and either give or remove that many points.
Future<void> _customPoints(BuildContext context, AppStore store, String personId, String handle) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final controller = TextEditingController();
  final choice = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.surface,
      title: Text(personId == 'me' ? 'Your points' : 'Points for @$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 7,
        decoration: InputDecoration(hintText: 'Amount', hintStyle: TextStyle(color: tokens.mute), counterText: ''),
        style: TextStyle(color: tokens.ink),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text('Cancel', style: TextStyle(color: tokens.mute))),
        TextButton(
          onPressed: () {
            final n = int.tryParse(controller.text.trim()) ?? 0;
            Navigator.of(dialogContext).pop(n > 0 ? -n : null);
          },
          child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
        ),
        TextButton(
          onPressed: () {
            final n = int.tryParse(controller.text.trim()) ?? 0;
            Navigator.of(dialogContext).pop(n > 0 ? n : null);
          },
          child: Text('Give', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  controller.dispose();
  if (choice == null || !context.mounted) return;
  await _givePoints(context, store, personId, handle, choice);
}
