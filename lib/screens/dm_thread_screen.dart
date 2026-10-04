import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';

/// A private 1:1 thread with one other person — reached from the Messages
/// tab in Chat, the "Message" button on someone's profile, or swiping up
/// on someone else's Story. Reuses the exact same ChatMessage/sendMessage
/// plumbing as the area live chat, just addressed to a per-pair room (see
/// dmRoomId) instead of 'main'.
///
/// IMPORTANT (see the "no backend" comment at the top of app_store.dart):
/// FUNKY has no server yet, so nothing sent here ever leaves this device —
/// this screen is real, working UI over real local data, but two different
/// phones can't actually exchange a DM until there's a backend to relay it.
class DmThreadScreen extends StatefulWidget {
  final String personId;
  const DmThreadScreen({super.key, required this.personId});

  @override
  State<DmThreadScreen> createState() => _DmThreadScreenState();
}

class _DmThreadScreenState extends State<DmThreadScreen> {
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send(AppStore store) {
    final text = _draftController.text.trim();
    if (text.isEmpty) return;
    Future<void> doSend() async {
      // Cleared up front so the input doesn't sit full while the real
      // (possibly network) send is in flight — same instant feel as before,
      // now that a real account's send is a genuine await instead of a
      // synchronous local-only write.
      _draftController.clear();
      final error = await store.sendDirectMessage(widget.personId, text);
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        return;
      }
      // Jump to the newest message once it's actually in the list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
    requireAccountThen(context, store, doSend);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final person = store.personById(widget.personId);

    if (person == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This person isn't around anymore tonight.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final isFriend = store.isFriendsWith(person.id);
    final room = dmRoomId('me', person.id);
    final msgs = store.messagesFor(room);

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            // Same green-ring treatment as the story rings on Home — makes
            // a friend's thread easier to pick out at a glance from a
            // stranger's.
            Container(
              padding: EdgeInsets.all(isFriend ? 2 : 0),
              decoration: isFriend ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.friend, width: 2)) : null,
              child: FunkyAvatar(seed: person.id, label: person.handle.isNotEmpty ? person.handle : '?', size: 30, photoPath: person.photoPath),
            ),
            const SizedBox(width: 10),
            Expanded(child: StyledName(person: person, text: '@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15))),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: msgs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: EmptyNote(
                          text: isFriend
                              ? 'Nothing here yet — say hey to @${person.handle}.'
                              : "Nothing here yet — you don't have to be friends to message someone on FUNKY.",
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) => _DmBubble(message: msgs[i], tokens: tokens),
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: tokens.surface, border: Border(top: BorderSide(color: tokens.line))),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _draftController,
                        maxLength: 240,
                        decoration: InputDecoration(
                          hintText: 'Message @${person.handle}',
                          hintStyle: TextStyle(color: tokens.mute),
                          filled: true,
                          fillColor: tokens.raised,
                          counterText: '',
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(19), borderSide: BorderSide.none),
                        ),
                        style: TextStyle(color: tokens.ink),
                        onSubmitted: (_) => _send(store),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _send(store),
                      child: Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: tokens.brand, shape: BoxShape.circle),
                        child: const Icon(Icons.arrow_upward, color: Colors.white, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DmBubble extends StatelessWidget {
  final ChatMessage message;
  final ThemeTokens tokens;
  const _DmBubble({required this.message, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final mine = message.uid == 'me';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
        decoration: BoxDecoration(
          color: mine ? tokens.brand : tokens.raised,
          borderRadius: BorderRadius.circular(16),
        ),
        child: filteredMessageText(message.text, TextStyle(color: mine ? tokens.onOrange : tokens.ink)),
      ),
    );
  }
}
