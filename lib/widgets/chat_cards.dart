import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../screens/event_pass_screen.dart';
import '../screens/place_detail_screen.dart';
import 'ios_ui.dart';
import 'ui_widgets.dart';

/// The payment apps a card can have, in the order they show.
const payAppOrder = ['venmo', 'cashapp', 'paypal', 'zelle', 'applecash'];

String payAppLabel(String app) => switch (app) {
      'venmo' => 'Venmo',
      'cashapp' => 'Cash App',
      'paypal' => 'PayPal',
      'zelle' => 'Zelle',
      'applecash' => 'Apple Cash',
      'cash' => 'cash',
      _ => 'another app',
    };

Color payAppColor(String app) => switch (app) {
      'venmo' => const Color(0xFF008CFF),
      'cashapp' => const Color(0xFF00B843),
      'paypal' => const Color(0xFF003087),
      'zelle' => const Color(0xFF6D1ED4),
      _ => const Color(0xFF1C1C1E),
    };

/// What someone types for each app ("@mike-delta", "$mike", ...).
String payHandleHint(String app) => switch (app) {
      'venmo' => '@username',
      'cashapp' => r'$cashtag',
      'paypal' => 'paypal.me name',
      'zelle' => 'Email or phone on Zelle',
      'applecash' => 'Phone or email for Apple Cash',
      _ => '',
    };

/// How a handle shows on a card.
String payHandleShown(String app, String handle) => switch (app) {
      'venmo' => '@$handle',
      'cashapp' => '\$$handle',
      'paypal' => 'paypal.me/$handle',
      _ => handle,
    };

String formatAmount(String? amount) {
  if (amount == null || amount.isEmpty) return '';
  final v = double.tryParse(amount);
  if (v == null) return '\$$amount';
  return v == v.roundToDouble() ? '\$${v.round()}' : '\$${v.toStringAsFixed(2)}';
}

/// Opens the payment app ready to pay [handle] (with the amount and note
/// filled in where the app allows it). Zelle has no link, so it copies.
Future<void> openPayApp(BuildContext context, String app, String handle, {String? amount, String? note}) async {
  final messenger = ScaffoldMessenger.of(context);
  Future<bool> tryOpen(Uri u) async {
    try {
      return await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  final amt = amount == null || amount.isEmpty ? null : amount;
  var ok = false;
  switch (app) {
    case 'venmo':
      ok = await tryOpen(Uri(scheme: 'venmo', host: 'paycharge', queryParameters: {
        'txn': 'pay',
        'recipients': handle,
        if (amt != null) 'amount': amt,
        if (note != null && note.isNotEmpty) 'note': note,
      }));
      if (!ok) ok = await tryOpen(Uri.parse('https://venmo.com/u/${Uri.encodeComponent(handle)}'));
    case 'cashapp':
      ok = await tryOpen(Uri.parse('https://cash.app/\$${Uri.encodeComponent(handle)}${amt != null ? '/$amt' : ''}'));
    case 'paypal':
      ok = await tryOpen(Uri.parse('https://paypal.me/${Uri.encodeComponent(handle)}${amt != null ? '/${amt}USD' : ''}'));
    case 'applecash':
      // Apple Cash is sent from Messages: open a message to them.
      ok = await tryOpen(Uri(scheme: 'sms', path: handle));
      if (ok) {
        messenger.showSnackBar(const SnackBar(content: Text('In Messages, tap + and then Apple Cash to send it.')));
        return;
      }
    case 'zelle':
      break;
  }
  if (!ok) {
    await Clipboard.setData(ClipboardData(text: handle));
    messenger.showSnackBar(SnackBar(
      content: Text(app == 'zelle'
          ? 'Copied $handle — send it with Zelle in your bank\'s app.'
          : "Couldn't open ${payAppLabel(app)}, so we copied $handle."),
    ));
  }
}

/// Which app did you pay with? (Skips the question when there's only one.)
Future<String?> pickPaidVia(BuildContext context, Iterable<String> apps) async {
  final list = [for (final a in payAppOrder) if (apps.contains(a)) a];
  if (list.length == 1) return list.first;
  return showIosActionSheet<String>(
    context,
    title: 'How did you pay?',
    actions: [
      for (final a in list) IosSheetAction(payAppLabel(a), a, icon: Icons.check_circle_outline_rounded),
      const IosSheetAction('Cash', 'cash', icon: Icons.payments_outlined),
    ],
  );
}

/// A card inside a chat bubble: a payment card, "asked to go", or "you're in".
class ChatCardView extends StatelessWidget {
  final ChatCard card;
  final bool mine;
  // Who sent it ('me' for you) — the person to pay, or who asked.
  final String fromUid;
  // 'dm', 'group' or 'event' — where the card is, for "I paid".
  final String kind;
  final String messageId;
  // In an event chat: which event.
  final String? eventId;
  const ChatCardView({
    super.key,
    required this.card,
    required this.mine,
    required this.fromUid,
    required this.kind,
    required this.messageId,
    this.eventId,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final width = (MediaQuery.of(context).size.width * 0.72).clamp(220.0, 320.0);
    final Widget body = switch (card.type) {
      'ask' => _askBody(context, store, tokens),
      'entry' => _entryBody(context, store, tokens),
      _ => _payBody(context, store, tokens),
    };
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: card.isEntry ? tokens.friend.withValues(alpha: 0.6) : tokens.line, width: 1.2),
      ),
      child: body,
    );
  }

  String _handleOf(AppStore store, String uid) => uid == 'me' ? store.me.handle : (store.personById(uid)?.handle ?? 'someone');

  Widget _payBody(BuildContext context, AppStore store, ThemeTokens tokens) {
    final amount = formatAmount(card.amount);
    final apps = [for (final a in payAppOrder) if (card.apps.containsKey(a)) a];
    final myMark = card.paidBy('me');
    final who = _handleOf(store, fromUid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tokens.friend.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Icon(Icons.attach_money_rounded, color: tokens.friend, size: 21),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mine ? 'You requested' : 'Pay @$who',
                    style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                  Text(
                    amount.isEmpty ? 'Payment request' : amount,
                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: amount.isEmpty ? 17 : 26, height: 1.1),
                  ),
                ],
              ),
            ),
          ],
        ),
        if ((card.note ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(card.note!, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600, fontSize: 14)),
        ],
        const SizedBox(height: 10),
        if (!mine) ...[
          for (final a in apps)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => openPayApp(context, a, card.apps[a]!, amount: card.amount, note: card.note),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: payAppColor(a),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: Text(
                    a == 'zelle' ? 'Zelle · ${card.apps[a]}' : 'Pay on ${payAppLabel(a)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 2),
          if (myMark != null)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: tokens.friend, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'You said you paid · ${payAppLabel(myMark.via)}',
                    style: TextStyle(color: tokens.friend, fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  final via = await pickPaidVia(context, apps);
                  if (via == null || !context.mounted) return;
                  final err = await store.markPaymentSent(kind, messageId, via, placeId: eventId);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? "Told @$who you paid.")));
                },
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: tokens.line),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                ),
                child: Text('I paid', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            "FUNKY doesn't handle the money — only pay people you know.",
            style: TextStyle(color: tokens.mute, fontSize: 11),
          ),
        ] else ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in apps)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: payAppColor(a).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
                  child: Text(payAppLabel(a), style: TextStyle(color: tokens.ink, fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (card.paid.isEmpty)
            Text('Waiting for them to pay', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w600))
          else ...[
            for (final m in card.paid.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: tokens.friend, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '@${_handleOf(store, m.uid)} says they paid · ${payAppLabel(m.via)}',
                        style: TextStyle(color: tokens.ink, fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            if (card.paid.length > 6)
              Text('and ${card.paid.length - 6} more', style: TextStyle(color: tokens.mute, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Check your app to make sure it came through.', style: TextStyle(color: tokens.mute, fontSize: 11)),
          ],
        ],
      ],
    );
  }

  Place? _event(AppStore store) {
    final id = card.placeId;
    if (id == null) return null;
    for (final p in store.places) {
      if (p.id == id) return p;
    }
    return null;
  }

  Widget _askBody(BuildContext context, AppStore store, ThemeTokens tokens) {
    final ev = _event(store);
    final name = ev?.name ?? card.name ?? 'your event';
    final canAct = !mine && ev != null && store.canManageEvent(ev);
    if (canAct && !store.eventRequestsLoaded(ev.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.ensureEventRequests(ev.id));
    }
    final reqs = ev == null ? const <EventRequest>[] : store.eventRequests(ev.id);
    String? status;
    for (final r in reqs) {
      if (r.uid == fromUid) status = r.status;
    }
    final guest = ev == null ? false : store.eventGuests(ev.id).any((g) => g.uid == fromUid);
    if (guest) status = 'in';
    if (mine && ev != null) status = store.myRequestStatus(ev.id) ?? status;
    final statusText = switch (status) {
      'pay_sent' => mine ? 'The host sent how to pay' : 'Payment sent — waiting on them',
      'paid' => mine ? 'You said you paid — waiting on the host' : 'They say they paid — check your app',
      'in' => mine ? "You're in 🎉" : 'They\'re in ✓',
      'declined' => mine ? "The host couldn't fit you in" : 'You said no',
      _ => mine ? 'Waiting for the host to answer' : null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('🙋', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mine ? 'You asked to go' : '@${_handleOf(store, fromUid)} asked to go',
                      style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 12)),
                  Text('🔒 $name', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 16)),
                ],
              ),
            ),
          ],
        ),
        if (statusText != null) ...[
          const SizedBox(height: 8),
          Text(statusText, style: TextStyle(color: status == 'in' ? tokens.friend : tokens.mute, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ],
        if (canAct && status != 'in' && status != 'declined') ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (status == null || status == 'asked') ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final err = await store.sendEventPayCard(ev.id, fromUid);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Sent them how to pay.')));
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: tokens.line),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                    ),
                    child: Text('Send my Venmo', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: ElevatedButton(
                  onPressed: () => letInWithConfirm(context, store, ev, fromUid),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: Text('Let them in', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _entryBody(BuildContext context, AppStore store, ThemeTokens tokens) {
    final ev = _event(store);
    final name = ev?.name ?? card.name ?? 'the event';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('🎉', style: TextStyle(fontSize: 26)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mine ? 'You let them in' : "You're in", style: TextStyle(color: tokens.friend, fontWeight: FontWeight.w900, fontSize: 13)),
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 16)),
                ],
              ),
            ),
          ],
        ),
        if (!mine) ...[
          const SizedBox(height: 6),
          Text('Only works for your account — no code needed.', style: TextStyle(color: tokens.mute, fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: card.placeId == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: card.placeId!))),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: tokens.line),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: Text('Details', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: card.placeId == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) => EventPassScreen(placeId: card.placeId!),
                          )),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: Text('My pass', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Let @jake in?" — then lets them in and says so.
Future<void> letInWithConfirm(BuildContext context, AppStore store, Place ev, String uid) async {
  final handle = store.personById(uid)?.handle ?? 'them';
  final ok = await showIosDialog<bool>(
    context: context,
    builder: (ctx) => IosAlert(
      title: Text('Let @$handle in?'),
      content: Text(
        ev.entryPrice != null
            ? "Make sure their payment came through first. They'll get the address and time, the chat, and their pass."
            : "They'll get the address and time, the chat, and their pass.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not yet')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Let them in')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final err = await store.letIntoEvent(ev.id, uid);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? "@$handle is in 🎉")));
  }
}

/// "Request money": amount, what it's for, and which of your payment apps
/// to put on the card. Returns the card to send, or null.
Future<ChatCard?> showPayCardSheet(BuildContext context, {String? note, String? placeId, double? amount}) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  return showModalBottomSheet<ChatCard>(
    context: context,
    backgroundColor: tokens.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _PayCardSheet(note: note, placeId: placeId, amount: amount),
  );
}

class _PayCardSheet extends StatefulWidget {
  final String? note;
  final String? placeId;
  final double? amount;
  const _PayCardSheet({this.note, this.placeId, this.amount});

  @override
  State<_PayCardSheet> createState() => _PayCardSheetState();
}

class _PayCardSheetState extends State<_PayCardSheet> {
  late final TextEditingController _amount;
  late final TextEditingController _note;
  final Map<String, TextEditingController> _handles = {};
  final Set<String> _on = {};
  bool _editing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final a = widget.amount;
    _amount = TextEditingController(text: a == null ? '' : (a == a.roundToDouble() ? '${a.round()}' : a.toStringAsFixed(2)));
    _note = TextEditingController(text: widget.note ?? '');
    final saved = context.read<AppStore>().payHandles.apps;
    for (final app in payAppOrder) {
      _handles[app] = TextEditingController(text: saved[app] ?? '');
      if (saved.containsKey(app)) _on.add(app);
    }
    _editing = saved.isEmpty;
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    for (final c in _handles.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _clean(String app, String v) {
    var s = v.trim();
    if (app == 'venmo') s = s.replaceFirst(RegExp(r'^@'), '');
    if (app == 'cashapp') s = s.replaceFirst(RegExp(r'^\$'), '');
    if (app == 'paypal') s = s.replaceFirst(RegExp(r'^(https?://)?(www\.)?paypal\.me/', caseSensitive: false), '');
    return s;
  }

  Future<void> _send() async {
    if (_busy) return;
    final store = context.read<AppStore>();
    final amtText = _amount.text.trim().replaceAll(r'$', '');
    final amt = amtText.isEmpty ? null : double.tryParse(amtText);
    if (amtText.isNotEmpty && (amt == null || amt <= 0 || amt > 99999)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Type the amount as a number, like 10.')));
      return;
    }
    if (_editing) {
      setState(() => _busy = true);
      final err = await store.savePayHandles(PaymentHandles(
        venmo: _clean('venmo', _handles['venmo']!.text),
        cashapp: _clean('cashapp', _handles['cashapp']!.text),
        paypal: _clean('paypal', _handles['paypal']!.text),
        zelle: _handles['zelle']!.text.trim(),
        applecash: _handles['applecash']!.text.trim(),
      ));
      if (!mounted) return;
      setState(() => _busy = false);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _on
        ..clear()
        ..addAll(store.payHandles.apps.keys);
    }
    final saved = store.payHandles.apps;
    final apps = {for (final a in _on) if (saved[a] != null) a: saved[a]!};
    if (apps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add at least one payment app.')));
      return;
    }
    String? amountStr;
    if (amt != null) amountStr = amt == amt.roundToDouble() ? '${amt.round()}' : amt.toStringAsFixed(2);
    final note = _note.text.trim();
    Navigator.of(context).pop(ChatCard(
      type: 'pay',
      amount: amountStr,
      note: note.isEmpty ? null : (note.length > 80 ? note.substring(0, 80) : note),
      apps: apps,
      placeId: widget.placeId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final saved = store.payHandles.apps;
    InputDecoration deco(String hint, {String? prefix}) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: tokens.mute, fontWeight: FontWeight.w400),
          prefixText: prefix,
          isDense: true,
          filled: true,
          fillColor: tokens.raised,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Request money', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 21)),
              const SizedBox(height: 4),
              Text("They tap your app on the card and pay you there. FUNKY never touches the money.",
                  style: TextStyle(color: tokens.mute, fontSize: 13)),
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 20),
                      decoration: deco('0', prefix: r'$ '),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _note,
                      maxLength: 80,
                      style: TextStyle(color: tokens.ink),
                      decoration: deco("What's it for?").copyWith(counterText: ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text('Your payment apps', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 12.5))),
                  if (saved.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _editing = !_editing),
                      child: Text(_editing ? 'Done' : 'Edit', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                    ),
                ],
              ),
              if (_editing) ...[
                for (final app in payAppOrder)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 86,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: payAppColor(app), borderRadius: BorderRadius.circular(8)),
                          child: Text(payAppLabel(app), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _handles[app],
                            autocorrect: false,
                            style: TextStyle(color: tokens.ink),
                            decoration: deco(payHandleHint(app)),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text("Saved for next time, only for cards you send.", style: TextStyle(color: tokens.mute, fontSize: 11.5)),
              ] else
                for (final app in payAppOrder)
                  if (saved[app] != null)
                    CheckboxListTile(
                      value: _on.contains(app),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: tokens.brand,
                      onChanged: (v) => setState(() => v == true ? _on.add(app) : _on.remove(app)),
                      title: Text(payAppLabel(app), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                      subtitle: Text(payHandleShown(app, saved[app]!), style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(_busy ? 'Saving…' : 'Send card', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
