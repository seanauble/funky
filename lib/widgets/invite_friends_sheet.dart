import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import 'avatar_preview.dart';
import 'ui_widgets.dart';

/// Pick friends and send them an in-app invite to [place]. For a private
/// event the host's invite lets them in without the code.
Future<void> showInviteFriendsSheet(BuildContext context, Place place) async {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final message = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _InviteSheet(place: place),
  );
  if (message != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _InviteSheet extends StatefulWidget {
  final Place place;
  const _InviteSheet({required this.place});

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _search = TextEditingController();
  final Set<String> _picked = {};
  bool _sending = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _send(AppStore store) async {
    if (_picked.isEmpty || _sending) return;
    setState(() => _sending = true);
    final msg = await store.inviteFriendsTo(widget.place.id, _picked.toList());
    if (!mounted) return;
    Navigator.of(context).pop(msg);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final q = _search.text.trim().toLowerCase();
    final friends = store.myFriends.where((f) => !store.isHidden(f.id) && (q.isEmpty || f.handle.toLowerCase().contains(q))).toList()
      ..sort((a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()));
    final place = widget.place;
    final height = MediaQuery.of(context).size.height * 0.75;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 2),
                child: Text('Invite friends', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Text(
                  place.isPrivate
                      ? "To ${place.name}. They'll get in without the code."
                      : 'To ${place.name}. They get a notification.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.mute, fontSize: 13),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(color: tokens.ink),
                  decoration: InputDecoration(
                    hintText: 'Search friends',
                    hintStyle: TextStyle(color: tokens.mute),
                    prefixIcon: Icon(Icons.search_rounded, color: tokens.mute),
                    filled: true,
                    fillColor: tokens.raised,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: friends.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            store.myFriends.isEmpty ? 'Add some friends first, then you can invite them.' : 'Nobody by that name.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: tokens.mute),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: friends.length,
                        itemBuilder: (context, i) {
                          final f = friends[i];
                          final already = store.hasInvited(place.id, f.id);
                          final on = _picked.contains(f.id);
                          return ListTile(
                            onTap: already
                                ? null
                                : () => setState(() {
                                      if (on) {
                                        _picked.remove(f.id);
                                      } else if (_picked.length < 50) {
                                        _picked.add(f.id);
                                      }
                                    }),
                            leading: PersonAvatar(person: f, size: 40, preview: false),
                            title: Text('@${f.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                            trailing: already
                                ? Text('Invited', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 13))
                                : AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: on ? tokens.orange : Colors.transparent,
                                      border: Border.all(color: on ? tokens.orange : tokens.line, width: 2),
                                    ),
                                    child: on ? const Icon(Icons.check_rounded, color: Colors.white, size: 16) : null,
                                  ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _picked.isEmpty || _sending ? null : () => _send(store),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tokens.orange,
                      disabledBackgroundColor: tokens.raised,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(
                            _picked.isEmpty ? 'Pick friends to invite' : (_picked.length == 1 ? 'Send invite' : 'Send ${_picked.length} invites'),
                            style: TextStyle(color: _picked.isEmpty ? tokens.mute : tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 15.5),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
