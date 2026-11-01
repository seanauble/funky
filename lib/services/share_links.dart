import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where people get FUNKY right now — the public TestFlight beta link.
/// Swap this for the App Store link once FUNKY is live there.
const funkyDownloadUrl = 'https://testflight.apple.com/join/aysuN3as';

/// Opens the phone's share sheet with [text]. If sharing isn't available it
/// copies the text instead and says so.
Future<void> _shareText(BuildContext context, String text) async {
  try {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'FUNKY',
      sharePositionOrigin: box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied — paste it anywhere.')));
    }
  }
}

/// Shares a FUNKY profile, with the link to get the app.
Future<void> shareFunkyProfile(BuildContext context, String handle, {bool mine = false}) {
  final text = mine
      ? "I'm on FUNKY 🕺 Add me: @$handle\nGet the app: $funkyDownloadUrl"
      : 'Check out @$handle on FUNKY 🕺\nGet the app: $funkyDownloadUrl';
  return _shareText(context, text);
}

/// "Bring your friends to Funky" — an invite with the link to get the app.
Future<void> shareFunkyInvite(BuildContext context, {String? handle}) {
  final who = handle == null ? '' : ' Add me: @$handle.';
  return _shareText(context, "Come out with me on FUNKY 🕺 See where everyone's going tonight.$who\nGet the app: $funkyDownloadUrl");
}

/// Shares a party, event or spot.
Future<void> shareFunkyPlace(BuildContext context, String name, {String? when}) {
  final at = when == null ? '' : ' ($when)';
  return _shareText(context, "Pull up to $name$at 🕺 See who's going on FUNKY.\nGet the app: $funkyDownloadUrl");
}

/// Opens Apple Maps with directions to a spot.
Future<void> openDirections(BuildContext context, double lat, double lng, String name) async {
  final uri = Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&q=${Uri.encodeComponent(name)}');
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open Maps.")));
  }
}
