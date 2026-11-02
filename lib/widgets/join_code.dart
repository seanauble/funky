import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_store.dart';
import '../screens/account_screen.dart';
import '../screens/place_detail_screen.dart';
import 'ios_ui.dart';

/// "Have a code?" — type the code a host sent you and you're in, no matter
/// which event it's for.
Future<void> showJoinWithCode(BuildContext context) async {
  final store = context.read<AppStore>();
  if (!store.signedIn) {
    await requireAccountThen(context, store, () {});
    return;
  }
  final field = TextEditingController();
  final code = await showIosDialog<String>(
    context: context,
    builder: (ctx) => IosAlert(
      title: const Text('Have a code?'),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the code a host sent you to get into their event.'),
            const SizedBox(height: 10),
            TextField(
              controller: field,
              autofocus: true,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              maxLength: 12,
              style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2),
              decoration: const InputDecoration(counterText: '', hintText: 'CODE', isDense: true),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Get in')),
      ],
    ),
  );
  field.dispose();
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  final (placeId, err) = await store.joinWithCode(code);
  if (!context.mounted) return;
  if (err != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    return;
  }
  if (placeId == null) return;
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You're in 🎉")));
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
}
