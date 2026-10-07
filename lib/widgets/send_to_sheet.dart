import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import 'avatar_preview.dart';
import 'ui_widgets.dart';

/// Who a snap should go to, picked in [showSendToSheet].
class SendTargets {
  final List<String> personIds;
  final List<String> groupIds;
  const SendTargets({required this.personIds, required this.groupIds});

  int get count => personIds.length + groupIds.length;
}

/// A bottom sheet listing your groups and friends (searchable, several can
/// be ticked) — resolves to who was picked, or null if dismissed.
Future<SendTargets?> showSendToSheet(BuildContext context) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  return showModalBottomSheet<SendTargets>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    builder: (_) => const _SendToSheet(),
  );
}

class _SendToSheet extends StatefulWidget {
  const _SendToSheet();

  @override
  State<_SendToSheet> createState() => _SendToSheetState();
}

class _SendToSheetState extends State<_SendToSheet> {
  static const int _maxTargets = 15;
  final _people = <String>{};
  final _groups = <String>{};
  String _query = '';

  int get _count => _people.length + _groups.length;

  void _toggle(Set<String> set, String id) {
    setState(() {
      if (set.contains(id)) {
        set.remove(id);
      } else if (_count < _maxTargets) {
        set.add(id);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You can send to up to 15 at a time.')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    final groups = store.groupConversations.where((g) => q.isEmpty || g.name.toLowerCase().contains(q)).toList();
    final friends = store.groupablePeople.where((p) => q.isEmpty || p.handle.toLowerCase().contains(q)).toList();

    Widget check(bool on) => Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, color: on ? tokens.brand : tokens.mute);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 4),
              child: Row(
                children: [
                  Expanded(child: Text('Send to', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800))),
                  TextButton(
                    onPressed: _count == 0
                        ? null
                        : () => Navigator.of(context).pop(SendTargets(personIds: _people.toList(), groupIds: _groups.toList())),
                    child: Text(
                      _count == 0 ? 'Send' : 'Send ($_count)',
                      style: TextStyle(color: _count == 0 ? tokens.mute : tokens.brand, fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: tokens.ink),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(color: tokens.mute),
                  prefixIcon: Icon(Icons.search, color: tokens.mute),
                  filled: true,
                  fillColor: tokens.raised,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: (groups.isEmpty && friends.isEmpty)
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: EmptyNote(text: store.groupablePeople.isEmpty ? 'Add some friends first, then you can send snaps to them.' : 'No matches.'),
                    )
                  : ListView(
                      children: [
                        if (groups.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 6, 18, 2),
                            child: Text('GROUPS', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.4)),
                          ),
                        for (final g in groups)
                          ListTile(
                            onTap: () => _toggle(_groups, g.id),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle),
                              child: const Icon(Icons.groups_rounded, color: Colors.white, size: 20),
                            ),
                            title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                            subtitle: Text('${g.memberIds.length} people', style: TextStyle(color: tokens.mute, fontSize: 12)),
                            trailing: check(_groups.contains(g.id)),
                          ),
                        if (friends.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
                            child: Text('FRIENDS', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.4)),
                          ),
                        for (final Person p in friends)
                          ListTile(
                            onTap: () => _toggle(_people, p.id),
                            leading: PersonAvatar(person: p, size: 38, preview: false),
                            title: Text('@${p.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                            trailing: check(_people.contains(p.id)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
