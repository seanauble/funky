import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/chat_cards.dart';
import '../widgets/ui_widgets.dart';

/// Your Venmo, Cash App, PayPal, Zelle and Apple Cash — what goes on the
/// payment cards you send. Only shown on cards you send, never on your profile.
class PaymentAppsScreen extends StatefulWidget {
  const PaymentAppsScreen({super.key});

  @override
  State<PaymentAppsScreen> createState() => _PaymentAppsScreenState();
}

class _PaymentAppsScreenState extends State<PaymentAppsScreen> {
  final Map<String, TextEditingController> _c = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final saved = context.read<AppStore>().payHandles.apps;
    for (final app in payAppOrder) {
      _c[app] = TextEditingController(text: saved[app] == null ? '' : payHandleShown(app, saved[app]!));
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _clean(String app) {
    var s = _c[app]!.text.trim();
    if (app == 'venmo') s = s.replaceFirst(RegExp(r'^@'), '');
    if (app == 'cashapp') s = s.replaceFirst(RegExp(r'^\$'), '');
    if (app == 'paypal') s = s.replaceFirst(RegExp(r'^(https?://)?(www\.)?paypal\.me/', caseSensitive: false), '');
    return s;
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final store = context.read<AppStore>();
    final err = await store.savePayHandles(PaymentHandles(
      venmo: _clean('venmo'),
      cashapp: _clean('cashapp'),
      paypal: _clean('paypal'),
      zelle: _clean('zelle'),
      applecash: _clean('applecash'),
    ));
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Saved.')));
    if (err == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: const Text('Payment apps'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving…' : 'Save', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            "These go on the payment cards you send in chats — for party entry, splitting a tab, anything. "
            "People tap your app on the card and pay you there. FUNKY never touches the money, and these never show on your profile.",
            style: TextStyle(color: tokens.mute, fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 16),
          for (final app in payAppOrder)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 96,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: payAppColor(app), borderRadius: BorderRadius.circular(10)),
                    child: Text(payAppLabel(app), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _c[app],
                      autocorrect: false,
                      keyboardType: app == 'zelle' || app == 'applecash' ? TextInputType.emailAddress : TextInputType.text,
                      style: TextStyle(color: tokens.ink),
                      decoration: InputDecoration(
                        hintText: payHandleHint(app),
                        hintStyle: TextStyle(color: tokens.mute),
                        isDense: true,
                        filled: true,
                        fillColor: tokens.raised,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'Zelle has no link to open, so people get your email or phone copied to paste in their bank app. '
            'Apple Cash opens a message to you — they send it from Messages.',
            style: TextStyle(color: tokens.mute, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }
}
