import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/post_models.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ios_ui.dart';
import '../widgets/poll_card.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';

/// A poll on its own page: vote, read everyone's comments, add yours.
class PollCommentsScreen extends StatefulWidget {
  final String pollId;
  const PollCommentsScreen({super.key, required this.pollId});

  @override
  State<PollCommentsScreen> createState() => _PollCommentsScreenState();
}

class _PollCommentsScreenState extends State<PollCommentsScreen> {
  final _controller = TextEditingController();
  Timer? _poll;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    await context.read<AppStore>().refreshPollComments(widget.pollId);
  }

  void _send(AppStore store) {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    requireAccountThen(context, store, () async {
      setState(() => _sending = true);
      final err = await store.addPollComment(widget.pollId, text);
      if (!mounted) return;
      setState(() => _sending = false);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _controller.clear();
    });
  }

  Future<void> _delete(AppStore store, PostComment c) async {
    final ok = await showIosActionSheet<bool>(
      context,
      message: maskBadWords(c.text),
      actions: const [IosSheetAction('Delete comment', true, destructive: true)],
    );
    if (ok == true) await store.deletePollComment(c);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    Poll? poll;
    for (final p in store.polls) {
      if (p.id == widget.pollId) {
        poll = p;
        break;
      }
    }
    final comments = store.pollCommentsFor(widget.pollId);

    return Scaffold(
      backgroundColor: tokens.bg,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Poll')),
      body: poll == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text("This poll isn't around anymore. Polls end at the 2 PM reset.", textAlign: TextAlign.center, style: TextStyle(color: tokens.mute)),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      PollCard(poll: poll, inDetail: true),
                      Text(
                        comments.isEmpty ? 'No comments yet. Say something.' : 'Comments',
                        style: TextStyle(color: comments.isEmpty ? tokens.mute : tokens.ink, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      for (final c in comments)
                        Builder(builder: (context) {
                          final person = store.personById(c.uid);
                          final handle = c.uid == 'me' ? store.myChatHandle : (person?.handle ?? 'someone');
                          final canDelete = c.uid == 'me' || poll!.by == 'me' || store.isAdmin;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: canDelete ? () => _delete(store, c) : null,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GestureDetector(
                                    onTap: () => openProfile(context, c.uid),
                                    child: person != null
                                        ? PersonAvatar(person: person, size: 32, preview: false)
                                        : FunkyAvatar(seed: c.uid, label: '?', size: 32),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text.rich(TextSpan(children: [
                                          TextSpan(text: '@$handle ', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                                          TextSpan(text: maskBadWords(c.text), style: TextStyle(color: tokens.ink)),
                                        ])),
                                        const SizedBox(height: 2),
                                        Row(
                                          children: [
                                            Text(timeAgoLabel(c.t), style: TextStyle(color: tokens.mute, fontSize: 12)),
                                            if (canDelete) ...[
                                              const SizedBox(width: 12),
                                              GestureDetector(
                                                onTap: () => _delete(store, c),
                                                child: Text('Delete', style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w700)),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
                ComposerArea(
                  color: tokens.surface,
                  border: Border(top: BorderSide(color: tokens.line)),
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          maxLength: 300,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          style: TextStyle(color: tokens.ink),
                          decoration: InputDecoration(
                            hintText: store.canCommentOnPoll(widget.pollId) ? 'Add a comment…' : "Comments open once the poll is posted",
                            hintStyle: TextStyle(color: tokens.mute),
                            filled: true,
                            fillColor: tokens.raised,
                            counterText: '',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Send',
                        onPressed: _sending ? null : () => _send(store),
                        icon: _sending
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                            : Icon(Icons.send_rounded, color: tokens.orange),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
