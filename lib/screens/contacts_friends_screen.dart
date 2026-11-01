import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../services/share_links.dart';
import '../theme/colors.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';

/// "Find friends from contacts": asks for contacts access, checks which of
/// your contacts' email addresses belong to FUNKY accounts (only hashes of
/// the addresses are sent; nothing is saved), and lists them with Add.
/// Anyone not on FUNKY yet can be sent the invite link.
class ContactsFriendsScreen extends StatefulWidget {
  const ContactsFriendsScreen({super.key});

  @override
  State<ContactsFriendsScreen> createState() => _ContactsFriendsScreenState();
}

class _ContactsFriendsScreenState extends State<ContactsFriendsScreen> {
  bool _loading = false;
  bool _denied = false;
  bool _searched = false;
  int _contactCount = 0;
  List<Person> _found = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<AppStore>().signedIn) _search();
    });
  }

  Future<void> _search() async {
    final store = context.read<AppStore>();
    setState(() {
      _loading = true;
      _denied = false;
    });
    try {
      final ok = await FlutterContacts.requestPermission(readonly: true);
      if (!ok) {
        if (mounted) {
          setState(() {
            _denied = true;
            _loading = false;
          });
        }
        return;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final emails = <String>[
        for (final c in contacts)
          for (final e in c.emails) e.address,
      ];
      final found = await store.matchContacts(emails);
      if (!mounted) return;
      setState(() {
        _contactCount = contacts.length;
        _found = found;
        _searched = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    Widget body;
    if (!store.signedIn) {
      body = _Note(
        tokens: tokens,
        text: 'Make a free account to add friends.',
        action: 'Create an account',
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen(closeOnSuccess: true))),
      );
    } else if (_loading) {
      body = const Center(child: Padding(padding: EdgeInsets.only(top: 60), child: CircularProgressIndicator()));
    } else if (_denied) {
      body = _Note(
        tokens: tokens,
        text: "FUNKY can't see your contacts. You can allow it in the iPhone Settings app under FUNKY → Contacts, or just search by @username.",
        action: 'Try again',
        onAction: _search,
      );
    } else if (!_searched) {
      body = _Note(
        tokens: tokens,
        text: 'See which of your contacts are already on FUNKY. Only scrambled versions of their email addresses are checked, and nothing is saved.',
        action: 'Check my contacts',
        onAction: _search,
      );
    } else {
      body = ListView(
        children: [
          Text(
            _found.isEmpty
                ? 'None of your $_contactCount contacts are on FUNKY yet (we match by email address).'
                : '${_found.length} of your contacts ${_found.length == 1 ? 'is' : 'are'} on FUNKY',
            style: TextStyle(color: tokens.mute, fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (final p in _found) _ContactRow(person: p),
          const SizedBox(height: 12),
          FunkyCard(
            child: Row(
              children: [
                Icon(Icons.ios_share, color: tokens.brand),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Invite the rest. Send them the link to get FUNKY.', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                ),
                Builder(
                  builder: (c) => TextButton(
                    onPressed: () => shareFunkyInvite(c, handle: store.me.handle),
                    child: Text('Invite', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Friends from contacts')),
      body: Padding(padding: const EdgeInsets.all(16), child: body),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final Person person;
  const _ContactRow({required this.person});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final id = person.id;
    final p = store.personById(id) ?? person;
    final friend = store.isFriendsWith(id);
    final sent = store.hasSentRequestTo(id);
    final received = store.hasRequestFrom(id);
    String label;
    VoidCallback? onTap;
    if (friend) {
      label = 'Friends';
    } else if (sent) {
      label = 'Requested';
      onTap = () => store.cancelFriendRequest(id);
    } else if (received) {
      label = 'Accept';
      onTap = () => store.acceptFriendRequest(id);
    } else {
      label = 'Add';
      onTap = () => store.sendFriendRequest(id);
    }
    final primary = !friend && !sent;
    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          GestureDetector(onTap: () => openProfile(context, id), child: PersonAvatar(person: p, size: 40, preview: false)),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openProfile(context, id),
              child: Text('@${p.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
            ),
          ),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor: primary ? tokens.brand : tokens.raised,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: Text(label, style: TextStyle(color: primary ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final ThemeTokens tokens;
  final String text;
  final String action;
  final VoidCallback onAction;
  const _Note({required this.tokens, required this.text, required this.action, required this.onAction});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        FunkyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.contacts_outlined, color: tokens.brand, size: 28),
              const SizedBox(height: 10),
              Text(text, style: TextStyle(color: tokens.ink, height: 1.35)),
              const SizedBox(height: 12),
              FunkyChip(label: action, active: true, onPressed: onAction),
            ],
          ),
        ),
      ],
    );
  }
}
