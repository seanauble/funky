import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../data/when_labels.dart';
import '../services/share_links.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/ios_ui.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';

/// "Bring 5 friends, get a free night out." Your invite code, who you've
/// brought in, your reward passes, and the bars and clubs that take them.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<AppStore>().fetchReferralStatus().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    }));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _addCode(AppStore store) async {
    final text = _code.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final err = await store.useReferralCode(text);
    if (!mounted) return;
    setState(() => _busy = false);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? "Added! You'll both get points once you're active."),
    ));
    if (err == null) _code.clear();
  }

  Future<void> _usePass(AppStore store, RewardPass pass) async {
    final venues = store.rewardPlaces;
    if (venues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("No bars are taking passes near you yet — it'll keep until one does."),
      ));
      return;
    }
    final place = await pickRewardVenue(context, store);
    if (place == null || !mounted) return;
    final ok = await showIosDialog<bool>(
      context: context,
      builder: (ctx) => IosAlert(
        title: Text('Use your pass at ${place.name}?'),
        content: Text("${place.reward}\n\nOnly tap Use now in front of the staff — it works once and can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not yet')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Use now')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final (reward, err) = await store.redeemRewardPass(pass.id, place.id);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    HapticFeedback.heavyImpact();
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => RewardPassScreen(placeName: place.name, reward: reward ?? place.reward ?? '', usedAt: DateTime.now()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final r = store.referral;
    final per = r?.perReward ?? 5;
    final toward = r?.towardNext ?? 0;
    final ready = r?.unusedRewards ?? const <RewardPass>[];
    final venues = [...store.rewardPlaces];
    final here = store.location;
    if (here != null) {
      venues.sort((a, b) => milesBetween(here, LatLng(a.lat, a.lng)).compareTo(milesBetween(here, LatLng(b.lat, b.lng))));
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Invite friends')),
      body: !store.signedIn
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: EmptyNote(text: 'Make an account to get your invite code.'),
            )
          : RefreshIndicator(
              onRefresh: store.fetchReferralStatus,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  // ---- The big card ----
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [tokens.brand, tokens.orange],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('🎁', style: TextStyle(fontSize: 30)),
                        const SizedBox(height: 6),
                        Text(
                          'Bring $per friends,\nget a free night out',
                          style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w900, fontSize: 24, height: 1.1),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Free cover, skip the line, or whatever the bar's giving. Every friend who joins: +100 points for you, +50 for them.",
                          style: TextStyle(color: tokens.onOrange.withValues(alpha: 0.9), fontSize: 13.5, height: 1.3),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            for (var i = 0; i < per; i++)
                              Expanded(
                                child: Container(
                                  height: 34,
                                  margin: EdgeInsets.only(right: i == per - 1 ? 0 : 6),
                                  decoration: BoxDecoration(
                                    color: i < toward ? tokens.onOrange : tokens.onOrange.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    i < toward ? Icons.person_rounded : Icons.person_outline_rounded,
                                    size: 18,
                                    color: i < toward ? tokens.orange : tokens.onOrange.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          ready.isNotEmpty
                              ? '${ready.length == 1 ? 'A pass is' : '${ready.length} passes are'} ready to use 🎉'
                              : '$toward of $per friends · ${per - toward} more to go',
                          style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 13.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // ---- Your code ----
                  FunkyCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('YOUR INVITE CODE', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 11.5, letterSpacing: 0.6)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: _loading && r?.code == null
                                  ? Text('······', style: TextStyle(color: tokens.mute, fontSize: 28, fontWeight: FontWeight.w900))
                                  : SelectableText(
                                      r?.code ?? '@${store.me.handle}',
                                      style: TextStyle(color: tokens.ink, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3),
                                    ),
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: r?.code ?? '@${store.me.handle}'));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
                                }
                              },
                              icon: Icon(Icons.copy_rounded, size: 16, color: tokens.brand),
                              label: Text('Copy', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                        Text(
                          'Friends type this (or @${store.me.handle}) in Invite friends when they join.',
                          style: TextStyle(color: tokens.mute, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: Builder(
                            builder: (c) => ElevatedButton.icon(
                              onPressed: () => shareFunkyInvite(c, handle: store.me.handle, code: r?.code),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: tokens.brand,
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: Icon(Icons.ios_share_rounded, color: tokens.onOrange, size: 18),
                              label: Text('Share your invite', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 15)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ---- Who invited you ----
                  if (r != null && r.canEnterCode) ...[
                    const SizedBox(height: 10),
                    FunkyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Did a friend invite you?', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text('Add their code and you both get points.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _code,
                                  textCapitalization: TextCapitalization.characters,
                                  autocorrect: false,
                                  style: TextStyle(color: tokens.ink),
                                  onSubmitted: (_) => _addCode(store),
                                  decoration: InputDecoration(
                                    hintText: 'Code or @username',
                                    hintStyle: TextStyle(color: tokens.mute),
                                    isDense: true,
                                    filled: true,
                                    fillColor: tokens.raised,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: _busy ? null : () => _addCode(store),
                                child: Text('Add', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ] else if (r?.invitedBy != null) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        "You joined with @${store.personById(r!.invitedBy!)?.handle ?? 'a friend'}'s code${r.invitedByCounts ? ' ✓' : ' · you count for them once you post, say where you\'re going, or add a friend'}",
                        style: TextStyle(color: tokens.mute, fontSize: 12.5),
                      ),
                    ),
                  ],
                  // ---- Passes ----
                  if (r != null && r.rewards.isNotEmpty) ...[
                    SectionHeader(title: 'Your passes'),
                    for (final pass in r.rewards)
                      FunkyCard(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: pass.used ? tokens.raised : tokens.gold.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Text(pass.used ? '✓' : '🎟️', style: TextStyle(fontSize: 20, color: tokens.mute)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pass.used ? (pass.usedReward ?? 'Used') : 'Free night out',
                                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    pass.used
                                        ? 'Used${_placeName(store, pass.usedPlaceId)} · ${dayLabel(pass.usedAt!)} ${clockLabel(pass.usedAt!)}'
                                        : 'Earned ${dayLabel(pass.earnedAt)} · works once',
                                    style: TextStyle(color: tokens.mute, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (!pass.used)
                              ElevatedButton(
                                onPressed: () => _usePass(store, pass),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: tokens.gold,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: const Text('Use', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900)),
                              )
                            else if (DateTime.now().difference(pass.usedAt!) < const Duration(hours: 12))
                              TextButton(
                                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                  fullscreenDialog: true,
                                  builder: (_) => RewardPassScreen(
                                    placeName: _placeName(store, pass.usedPlaceId).replaceFirst(' at ', ''),
                                    reward: pass.usedReward ?? '',
                                    usedAt: pass.usedAt!,
                                  ),
                                )),
                                child: Text('Show', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                              ),
                          ],
                        ),
                      ),
                  ],
                  // ---- Friends ----
                  SectionHeader(title: 'Friends you brought in${r == null || r.invited.isEmpty ? '' : ' (${r.counted} count)'}'),
                  if (r == null || r.invited.isEmpty)
                    const EmptyNote(text: 'No one yet — share your code and they show up here.')
                  else
                    for (final f in r.invited)
                      Builder(builder: (context) {
                        final person = store.personById(f.uid);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              if (person != null) PersonAvatar(person: person, size: 36) else const SizedBox(width: 36, height: 36),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('@${person?.handle ?? 'someone'}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                                    Text(
                                      f.counts ? 'Counts ✓ · +100 points' : 'Joined · counts once they\'re active (a day in + one post, going or friend)',
                                      style: TextStyle(color: f.counts ? tokens.friend : tokens.mute, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  // ---- Where passes work ----
                  SectionHeader(title: 'Where passes work'),
                  if (venues.isEmpty)
                    const EmptyNote(text: "Bars and clubs are joining now. Your passes don't expire, so they'll keep until one near you does.")
                  else
                    for (final p in venues.take(20))
                      InkWell(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              Icon(Icons.local_bar_rounded, color: tokens.orange, size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                                    Text(
                                      '${p.reward}${here == null ? '' : ' · ${formatMiles(milesBetween(here, LatLng(p.lat, p.lng)))}'}',
                                      style: TextStyle(color: tokens.mute, fontSize: 12.5),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: tokens.mute),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 18),
                  Text(
                    "Friends count once their account is a day old and they've done one thing on FUNKY — posted, said where they're going, or added a friend. "
                    "One code per new account, in its first 2 weeks. The venue gives the reward and sets its own rules; you have to be 21+ for anything with alcohol. "
                    "Fake or duplicate accounts don't count, and passes from them can be taken back.",
                    style: TextStyle(color: tokens.mute, fontSize: 11.5, height: 1.35),
                  ),
                ],
              ),
            ),
    );
  }

  static String _placeName(AppStore store, String? placeId) {
    if (placeId == null) return '';
    for (final p in store.places) {
      if (p.id == placeId) return ' at ${p.name}';
    }
    return '';
  }
}

/// Pick which bar or club you're at, nearest first.
Future<Place?> pickRewardVenue(BuildContext context, AppStore store) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final venues = [...store.rewardPlaces];
  final here = store.location;
  if (here != null) {
    venues.sort((a, b) => milesBetween(here, LatLng(a.lat, a.lng)).compareTo(milesBetween(here, LatLng(b.lat, b.lng))));
  }
  return showModalBottomSheet<Place>(
    context: context,
    backgroundColor: tokens.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('Where are you?', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 19)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in venues)
                    ListTile(
                      leading: Icon(Icons.local_bar_rounded, color: tokens.orange),
                      title: Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        '${p.reward}${here == null ? '' : ' · ${formatMiles(milesBetween(here, LatLng(p.lat, p.lng)))}'}',
                        style: TextStyle(color: tokens.mute, fontSize: 12.5),
                      ),
                      onTap: () => Navigator.of(ctx).pop(p),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// The screen you show staff: a moving rainbow, a live clock (so it can't
/// be a screenshot), the reward and the bar.
class RewardPassScreen extends StatefulWidget {
  final String placeName;
  final String reward;
  final DateTime usedAt;
  const RewardPassScreen({super.key, required this.placeName, required this.reward, required this.usedAt});

  @override
  State<RewardPassScreen> createState() => _RewardPassScreenState();
}

class _RewardPassScreenState extends State<RewardPassScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  late final Timer _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    _spin.dispose();
    super.dispose();
  }

  String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    String two(int n) => n.toString().padLeft(2, '0');
    return '$h:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            gradient: SweepGradient(
              center: Alignment.center,
              transform: GradientRotation(_spin.value * 2 * pi),
              colors: const [
                Color(0xFFFF3B6B),
                Color(0xFFFF9F1C),
                Color(0xFFFFE14D),
                Color(0xFF3DDC84),
                Color(0xFF3AA8FF),
                Color(0xFFA259FF),
                Color(0xFFFF3B6B),
              ],
            ),
          ),
          child: child,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
                  ),
                ),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.verified_rounded, color: Color(0xFF3DDC84), size: 64),
                      const SizedBox(height: 8),
                      const Text('FUNKY REWARD', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w900, letterSpacing: 3, fontSize: 13)),
                      const SizedBox(height: 10),
                      Text(
                        widget.reward,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 32, height: 1.1),
                      ),
                      if (widget.placeName.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('at ${widget.placeName}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                      ],
                      const SizedBox(height: 18),
                      Text('@${store.me.handle}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(
                        'Used ${dayLabel(widget.usedAt)} at ${clockLabel(widget.usedAt)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 13.5),
                      ),
                      const SizedBox(height: 16),
                      Text(_clock(_now), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(height: 2),
                      const Text('live time — a screenshot won\'t tick', style: TextStyle(color: Colors.white54, fontSize: 11.5)),
                    ],
                  ),
                ),
                const Spacer(),
                const Text('Show this to the staff', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Did a friend invite you?" — asked once, right after a new account is
/// made. Skipping is fine; it's also on the Invite friends screen for 2 weeks.
Future<void> showWhoInvitedSheet(BuildContext context) async {
  final store = context.read<AppStore>();
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  final controller = TextEditingController();
  await store.markAskedWhoInvited();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: tokens.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) {
      var busy = false;
      String? error;
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> submit() async {
            if (busy || controller.text.trim().isEmpty) return;
            setSheet(() {
              busy = true;
              error = null;
            });
            final err = await store.useReferralCode(controller.text);
            if (!ctx.mounted) return;
            if (err != null) {
              setSheet(() {
                busy = false;
                error = err;
              });
              return;
            }
            Navigator.of(ctx).pop();
            messenger.showSnackBar(const SnackBar(content: Text("Added! You'll both get points once you're active.")));
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('🎟️', style: TextStyle(fontSize: 34)),
                  const SizedBox(height: 6),
                  Text('Did a friend invite you?', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 21)),
                  const SizedBox(height: 4),
                  Text(
                    'Add their code or @username — you get +50 points and they get closer to a free night out.',
                    style: TextStyle(color: tokens.mute, fontSize: 13.5, height: 1.3),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w700),
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      hintText: 'Code or @username',
                      hintStyle: TextStyle(color: tokens.mute, fontWeight: FontWeight.w400),
                      filled: true,
                      fillColor: tokens.raised,
                      errorText: error,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: busy ? null : submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tokens.brand,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(busy ? 'Adding…' : 'Add', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text('No one — skip', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  controller.dispose();
}
