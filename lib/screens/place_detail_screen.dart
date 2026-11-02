import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../widgets/ios_ui.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../widgets/place_rating_card.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'move_pin_screen.dart';
import 'place_story_viewer_screen.dart';
import 'posts_screen.dart';
import 'create_sheet.dart';
import '../widgets/kind_picker.dart';
import '../data/when_labels.dart';
import '../services/share_links.dart';
import '../widgets/avatar_preview.dart';
import '../widgets/full_art_image.dart';
import '../widgets/org_badge.dart';
import 'profile_parts.dart';
import 'event_chat_screen.dart';
import '../widgets/invite_friends_sheet.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'referral_screen.dart';
import 'dm_thread_screen.dart';
import 'event_manage_screen.dart';
import 'event_pass_screen.dart';
import '../widgets/chat_cards.dart' show formatAmount;

/// The little text box explaining what the verified checkmark (or the
/// not-yet-verified "?") next to a place's name means — its own tap
/// target, separate from the rest of the card.
void _showVerifiedExplainer(BuildContext context, {required bool isAdmin, required bool verified}) {
  final String message;
  if (isAdmin) {
    message = 'FUNKY Verified — confirmed legit by the FUNKY team.';
  } else if (verified) {
    message = 'FUNKY Verified — confirmed legit by the FUNKY community (15+ confirmations).';
  } else {
    message = "Not verified yet — tap Confirm below if you know this place is real and happening tonight.";
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

class PlaceDetailScreen extends StatefulWidget {
  final String placeId;
  const PlaceDetailScreen({super.key, required this.placeId});

  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  final _coverController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Everyone's posts tagged here, not just the recent ones.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AppStore>();
      store.fetchPostsAt(widget.placeId);
      final p = store.rankedPlaceById(widget.placeId)?.place;
      // Private: re-check the details (you may have just been invited),
      // who's going (the way the host shows it), and any requests to go.
      if (p != null && p.isPrivate) {
        store.refreshPrivateEvent(widget.placeId);
        store.fetchGoingPreview(widget.placeId);
        if (store.canManageEvent(p)) store.fetchEventRequests(widget.placeId);
      }
    });
  }

  @override
  void dispose() {
    _coverController.dispose();
    super.dispose();
  }

  void _submit(AppStore store, ReportKind kind, {String? detail}) {
    final blocked = store.reportBlockReason();
    if (blocked != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(blocked)));
      return;
    }
    store.submitReport(widget.placeId, kind, detail: detail);
  }

  bool _uploadingPhoto = false;

  /// Anyone signed in can suggest a picture for the place; a FUNKY Admin has
  /// to approve it before it shows up for everyone (an admin's own goes
  /// live right away).
  Future<void> _addPicture(AppStore store) async {
    final source = await showIosActionSheet<ImageSource>(
      context,
      title: 'Upload a verified picture',
      message: 'A FUNKY admin checks it first. You get 1,000 Funky Points once it\'s verified.',
      actions: const [
        IosSheetAction('Choose from Library', ImageSource.gallery),
        IosSheetAction('Take a Photo', ImageSource.camera),
      ],
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (picked == null || !mounted) return;
      setState(() => _uploadingPhoto = true);
      final message = await store.suggestPlacePhoto(widget.placeId, picked.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open that picture.")));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  void _confirm(AppStore store, String reportId) {
    final error = store.confirmReport(reportId);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _retract(AppStore store, String reportId) {
    final error = store.retractReport(reportId);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// FUNKY Admin only — confirms before permanently removing this place
  /// tonight (see AppStore.deletePlace), then pops back out since the page
  /// this screen is showing no longer exists.
  Future<void> _confirmDeletePlace(BuildContext context, AppStore store, String placeName) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final confirmed = await showIosDialog<bool>(
      context: context,
      builder: (dialogContext) => IosAlert(
        backgroundColor: tokens.surface,
        title: Text('Delete $placeName?', style: TextStyle(color: tokens.ink)),
        content: Text(
          "This removes it from tonight's list along with its reports and confirmations. This can't be undone.",
          style: TextStyle(color: tokens.mute),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Delete', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      store.deletePlace(widget.placeId);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  int _tab = 0; // 0 = Details, 1 = Memories

  /// "I'm going": ahead of time for an upcoming party, or tonight's move.
  Future<void> _toggleGoing(AppStore store, Place p, {required bool upcoming, required bool going}) async {
    if (upcoming) {
      await requireAccountThen(context, store, () async {
        final err = await store.togglePlaceRsvp(p.id);
        if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      });
      return;
    }
    if (going) {
      if (store.me.move == p.id) store.setMove('in');
      if (store.hasRsvped(p.id)) await store.togglePlaceRsvp(p.id);
    } else {
      store.setMove(p.id);
    }
  }

  /// "Ask to go": tells the host (with an optional note) and opens your
  /// chat with them, where they send how to pay and let you in.
  Future<void> _ask(AppStore store, Place p) async {
    if (!store.signedIn) {
      await requireAccountThen(context, store, () {});
      return;
    }
    final status = store.myRequestStatus(p.id);
    if (status != null && status != 'declined' && p.by != 'me') {
      await store.ensurePerson(p.by);
      if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: p.by)));
      return;
    }
    final field = TextEditingController();
    final note = await showIosDialog<String>(
      context: context,
      builder: (ctx) => IosAlert(
        title: Text('Ask to go to ${p.name}?'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.entryPrice != null
                  ? "The host gets your request in their messages. They'll send how to pay (${formatAmount(p.entryPrice!.toStringAsFixed(2))}), then let you in."
                  : "The host gets your request in their messages and can let you in."),
              const SizedBox(height: 10),
              TextField(
                controller: field,
                maxLength: 200,
                decoration: const InputDecoration(hintText: "Say who you are (optional)", counterText: '', isDense: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Ask')),
        ],
      ),
    );
    field.dispose();
    if (note == null || !mounted) return;
    final (host, err) = await store.askToJoin(p.id, note: note.trim().isEmpty ? null : note.trim());
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (host != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Asked! Watch your messages for the host.')));
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmThreadScreen(personId: host)));
    }
  }

  /// Enter the host's code (iOS alert with a text box).
  Future<void> _unlock(AppStore store, Place p) async {
    if (!store.signedIn) {
      await requireAccountThen(context, store, () {});
      return;
    }
    final field = TextEditingController();
    final code = await showIosDialog<String>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text('Enter the code'),
        content: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ask the host for it. It shows you the address and time, and lets you RSVP and join the chat.'),
              const SizedBox(height: 10),
              TextField(
                controller: field,
                autofocus: true,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                maxLength: 20,
                style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2),
                decoration: const InputDecoration(counterText: '', hintText: 'CODE', isDense: true),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Unlock')),
        ],
      ),
    );
    field.dispose();
    if (code == null || code.trim().isEmpty || !mounted) return;
    final err = await store.unlockPrivateEvent(p.id, code);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? "You're in! Let the host know if you're coming.")));
  }

  /// "Own or manage this place?" — a short form; an admin checks it.
  Future<void> _claim(AppStore store, Place p) async {
    if (!store.signedIn) {
      await requireAccountThen(context, store, () {});
      return;
    }
    final role = TextEditingController(text: 'Owner');
    final contact = TextEditingController();
    final note = TextEditingController();
    final send = await showIosDialog<bool>(
      context: context,
      builder: (ctx) => IosAlert(
        title: Text('Claim ${p.name}'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Run this page: post official events (verified right away), add pictures and set a deal. We'll check it's really you first."),
              const SizedBox(height: 10),
              TextField(controller: role, maxLength: 40, decoration: const InputDecoration(labelText: 'Your role (Owner, Manager…)', counterText: '', isDense: true)),
              TextField(
                controller: contact,
                maxLength: 120,
                decoration: const InputDecoration(labelText: "Bar's phone, email or Instagram", counterText: '', isDense: true),
              ),
              TextField(controller: note, maxLength: 300, decoration: const InputDecoration(labelText: 'Anything else (optional)', counterText: '', isDense: true)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Send')),
        ],
      ),
    );
    final r = role.text, c = contact.text, n = note.text;
    role.dispose();
    contact.dispose();
    note.dispose();
    if (send != true || !mounted) return;
    final msg = await store.submitPlaceClaim(p.id, role: r, contact: c, note: n);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Owner: the deal shown on the place ("No cover before 10").
  Future<void> _editDeal(AppStore store, Place p) async {
    final field = TextEditingController(text: p.deal ?? '');
    final value = await showIosDialog<String>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text("Tonight's deal"),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Shows on your page for everyone. Leave it empty to take it down.'),
              const SizedBox(height: 10),
              TextField(
                controller: field,
                autofocus: true,
                maxLength: 140,
                maxLines: 2,
                minLines: 1,
                decoration: const InputDecoration(hintText: 'No cover before 10 · \$5 apps', counterText: '', isDense: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (value == null || !mounted) return;
    final err = await store.setPlaceDeal(p.id, value);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? (value.trim().isEmpty ? 'Deal taken down.' : 'Deal is up.'))));
  }

  /// Owner or admin: what this place gives for a FUNKY reward pass.
  Future<void> _editReward(AppStore store, Place p) async {
    final field = TextEditingController(text: p.reward ?? '');
    final value = await showIosDialog<String>(
      context: context,
      builder: (ctx) => IosAlert(
        title: const Text('FUNKY Rewards'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "People who bring 5 friends onto FUNKY get a pass. What do you give them when they show it? "
                "You'll get a notification each time one's used here. Leave it empty to stop taking passes.",
              ),
              const SizedBox(height: 10),
              TextField(
                controller: field,
                autofocus: true,
                maxLength: 60,
                decoration: const InputDecoration(hintText: 'Free cover · Skip the line', counterText: '', isDense: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(field.text), child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (value == null || !mounted) return;
    final err = await store.setPlaceReward(p.id, value);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err ?? (value.trim().isEmpty ? "You're not taking FUNKY passes now." : "You're in — FUNKY passes work here now.")),
      ));
    }
  }

  Future<void> _pickRsvp(AppStore store, Place p) async {
    final status = await showIosActionSheet<String>(
      context,
      title: 'Are you going?',
      actions: const [
        IosSheetAction('Going', 'going', icon: Icons.check_circle_outline_rounded),
        IosSheetAction('Maybe', 'maybe', icon: Icons.help_outline_rounded),
        IosSheetAction("Can't go", 'cant', icon: Icons.cancel_outlined),
      ],
    );
    if (status == null || !mounted) return;
    final err = await store.setEventRsvp(p.id, status);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  void _showGuests(BuildContext context, AppStore store, Place p) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => Consumer<AppStore>(
        builder: (context, store, _) {
          final guests = store.eventGuests(p.id);
          const order = ['going', 'maybe', 'unlocked', 'cant'];
          const titles = {'going': 'Going', 'maybe': 'Maybe', 'unlocked': "Hasn't answered", 'cant': "Can't go"};
          final isHost = store.canManageEvent(p);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.75),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(0, 14, 0, 14),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
                    child: Text('Guest list', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
                  ),
                  if (isHost)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                      child: Text('Hold someone to take them off the list.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ),
                  if (guests.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                      child: Text('Nobody yet. Send people the code.', style: TextStyle(color: tokens.mute)),
                    ),
                  for (final status in order)
                    if (guests.any((g) => g.status == status)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                        child: Text(
                          '${titles[status]} · ${guests.where((g) => g.status == status).length}',
                          style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 13),
                        ),
                      ),
                      for (final g in guests.where((g) => g.status == status))
                        Builder(builder: (context) {
                          final person = g.uid == 'me' ? store.me : store.personById(g.uid);
                          return ListTile(
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              openProfile(this.context, g.uid);
                            },
                            onLongPress: isHost && g.uid != 'me'
                                ? () async {
                                    final ok = await showIosActionSheet<bool>(
                                      sheetContext,
                                      message: 'Take @${person?.handle ?? 'them'} off the guest list? They\'d need the code again.',
                                      actions: const [IosSheetAction('Remove from guest list', true, destructive: true)],
                                    );
                                    if (ok == true) await store.removeEventGuest(p.id, g.uid);
                                  }
                                : null,
                            leading: person != null
                                ? PersonAvatar(person: person, size: 38, preview: false)
                                : FunkyAvatar(seed: g.uid, label: '?', size: 38),
                            title: Text(
                              g.uid == 'me' ? 'You' : '@${person?.handle ?? 'someone'}',
                              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                            ),
                            subtitle: g.checkedInAt != null && store.isEventStaff(p)
                                ? Text('Checked in ${clockLabel(g.checkedInAt!)}', style: TextStyle(color: tokens.friend, fontSize: 12))
                                : null,
                            trailing: switch (store.roleAt(p, g.uid)) {
                              'host' => Text('Host', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 12.5)),
                              'cohost' => Text('Co-host', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 12.5)),
                              'door' => Text('Door', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: 12.5)),
                              _ => null,
                            },
                          );
                        }),
                    ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showGoing(BuildContext context, AppStore store, Place p) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final people = store.peopleGoingToPlace(p.id);
    final friends = store.me.friends.toSet();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                child: Text('Going to ${p.name}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              if (people.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
                  child: Text("Nobody's said they're going yet. Be the first.", style: TextStyle(color: tokens.mute)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 14),
                    children: [
                      for (final person in people)
                        ListTile(
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            openProfile(context, person.id);
                          },
                          leading: PersonAvatar(person: person, size: 38, preview: false),
                          title: Text(person.id == 'me' ? 'You' : '@${person.handle}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                          trailing: friends.contains(person.id)
                              ? Text('Friend', style: TextStyle(color: tokens.friend, fontWeight: FontWeight.w700, fontSize: 12.5))
                              : null,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final found = store.rankedPlaceById(widget.placeId);

    if (found == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This place isn't around anymore tonight.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final place = found;
    final p = place.place;
    final upcoming = store.isPlaceUpcoming(p);
    final tonight = store.isPlaceOnTonight(p);
    final over = !upcoming && !tonight;
    final going = upcoming ? store.hasRsvped(p.id) : (store.me.move == p.id || store.hasRsvped(p.id));
    final reports = store.reportsFor(place.id);
    final venueStories = store.storiesFor(place.id);
    final latestVenueStory = store.latestMediaStoryFor(place.id);
    final venueVerified = store.isPlaceVerified(place.id);
    final venueAdminVerified = store.isAdminVerified(place.id);
    final venueConfirmations = store.venueConfirmationCount(place.id);
    final iConfirmedVenue = store.hasConfirmedPlace(place.id);
    final badge = placeOrgBadge(p);
    // Private events: the address, time, guest list and chat are only for
    // the host and people who entered the code.
    final priv = p.isPrivate;
    final insider = store.isEventInsider(p);
    final locked = priv && !insider;
    final isHost = p.by == 'me';
    final myRsvp = store.myEventStatus(p.id);
    final secret = store.privateDetailsFor(p.id);
    final startsAt = p.shownTime;
    final isParty = const {PlaceKind.party, PlaceKind.event, PlaceKind.tailgate, PlaceKind.frat}.contains(p.kind);
    final guestsGoing = store.eventGuestCount(p.id, 'going');
    final guestsMaybe = store.eventGuestCount(p.id, 'maybe');
    final messageCount = store.eventMessages(p.id).length;
    Place? host;
    if (p.hostPlaceId != null) {
      for (final h in store.places) {
        if (h.id == p.hostPlaceId) {
          host = h;
          break;
        }
      }
    }
    final hosted = store.eventsHostedAt(p.id);
    final goingPeople = priv
        ? [
            for (final g in store.eventGuests(p.id).where((g) => g.status == 'going'))
              if ((g.uid == 'me' ? store.me : store.personById(g.uid)) case final person?) person,
          ]
        : store.peopleGoingToPlace(p.id);
    final friendsGoing = store.friendsGoingToPlace(p.id).length;
    final isVenue = p.kind == PlaceKind.bar || p.kind == PlaceKind.club;
    final artUrl = isVenue ? (p.photoUrl ?? p.coverUrl) : (p.coverUrl ?? p.photoUrl);
    final artPath = isVenue && p.photoUrl != null ? null : p.coverPhotoPath;
    final hasArt = artUrl != null || artPath != null;
    void openStories() => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PlaceStoryViewerScreen(placeId: place.id, placeName: place.name)),
        );

    final thumb = PlaceMediaThumbnail(
      story: latestVenueStory,
      coverPhotoPath: p.coverPhotoPath,
      coverUrl: p.coverUrl,
      photoUrl: p.photoUrl,
      fallbackLabel: p.name.isNotEmpty ? p.name.substring(0, 1) : '?',
      fontSize: 44,
    );
    final art = Stack(
      children: [
        hasArt
            ? FullArtImage(filePath: artPath, url: artUrl, fallback: thumb)
            : ClipRRect(borderRadius: BorderRadius.circular(14), child: AspectRatio(aspectRatio: 16 / 9, child: thumb)),
        if (badge != null) Positioned(top: 10, right: 10, child: OrgLettersBadge(badge: badge)),
        // Google photos need a visible credit.
        if (artUrl != null && artUrl == p.photoUrl && store.placePhotoCredits[place.id] != null)
          Positioned(
            left: 10,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text('Photo: ${store.placePhotoCredits[place.id]} · Google', style: const TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ),
        if (venueStories.isNotEmpty)
          Positioned(
            bottom: 10,
            right: 12,
            child: GestureDetector(
              onTap: openStories,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(999)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.camera_alt, color: Colors.white, size: 13),
                    const SizedBox(width: 5),
                    Text(
                      '${venueStories.length} Stor${venueStories.length == 1 ? 'y' : 'ies'} tonight',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    Widget infoRow(IconData icon, String title, String? sub, {VoidCallback? onTap, Widget? lead}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              SizedBox(width: 34, child: lead ?? Icon(icon, color: tokens.ink, size: 25)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                    if (sub != null && sub.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(sub, style: TextStyle(color: tokens.mute, fontSize: 13.5)),
                    ],
                  ],
                ),
              ),
              if (onTap != null) Icon(Icons.chevron_right_rounded, color: tokens.mute),
            ],
          ),
        ),
      );
    }

    final address = p.address.trim().isEmpty || p.address == 'Address not given' ? p.name : p.address;
    final inviters = store.invitedBy(p.id);
    final details = <Widget>[
      if (inviters.isNotEmpty)
        Builder(builder: (context) {
          final first = store.personById(inviters.first);
          return Container(
            margin: const EdgeInsets.only(top: 6, bottom: 4),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: tokens.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                if (first != null) PersonAvatar(person: first, size: 30, preview: false) else Icon(Icons.mail_outline_rounded, color: tokens.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '@${first?.handle ?? 'A friend'} invited you${inviters.length > 1 ? ' (+${inviters.length - 1} more)' : ''}',
                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
              ],
            ),
          );
        }),
      if (locked)
        _PrivateLockCard(
          night: p.startsAt == null ? 'Tonight' : (tonight ? 'Tonight' : dayLabel(p.startsAt!)),
          signedIn: store.signedIn,
          onUnlock: () => _unlock(store, p),
          onAsk: () => _ask(store, p),
          price: p.entryPrice,
          requestStatus: store.myRequestStatus(p.id),
          preview: store.goingPreviewFor(p.id),
        )
      else
        infoRow(
          Icons.location_on_outlined,
          address,
          '${priv ? '🔒 Private ${placeKindLabel(p.kind).toLowerCase()}' : placeKindLabel(p.kind)} · ${place.distance < 0.1 ? 'right by you' : '${formatMiles(place.distance)} away'}',
          onTap: () => openDirections(context, p.lat, p.lng, p.name),
        ),
      if (startsAt != null)
        infoRow(Icons.schedule_rounded, clockLabel(startsAt), '${dayLabel(startsAt)} · ${partOfNightLabel(startsAt)}'),
      if (priv && store.isEventStaff(p))
        _RunEventCard(
          role: store.eventRole(p) ?? 'host',
          openRequests: store.openRequestCount(p.id),
          checkedIn: store.eventGuests(p.id).where((g) => g.checkedInAt != null).length,
          onList: store.eventGuests(p.id).where((g) => g.status != 'cant').length,
          onOpen: (tab) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventManageScreen(placeId: p.id, initialTab: tab))),
        ),
      if (priv && insider) ...[
        Builder(builder: (context) {
          final preview = store.goingPreviewFor(p.id);
          final staff = store.isEventStaff(p);
          final hidden = p.hidesGoingCount && !staff;
          final faces = [
            for (final f in preview?.faces ?? const <String>[])
              if ((f == 'me' ? store.me : store.personById(f)) case final person?) person,
          ];
          return _RsvpCard(
            status: myRsvp,
            summary: hidden
                ? (faces.isEmpty ? 'The host keeps the guest list to themselves' : 'and ${preview?.more == true ? 'more' : 'others'} going')
                : '$guestsGoing going${guestsMaybe > 0 ? ' · $guestsMaybe maybe' : ''} · see the guest list',
            faces: hidden ? faces : const [],
            onPick: (s) async {
              final err = await store.setEventRsvp(p.id, s);
              if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
              unawaited(store.fetchGoingPreview(p.id));
            },
            onGuests: hidden ? null : () => _showGuests(context, store, p),
          );
        }),
        if (myRsvp != null && !store.isEventStaff(p))
          infoRow(
            Icons.confirmation_number_outlined,
            'Your pass',
            'Show it at the door',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => EventPassScreen(placeId: p.id))),
          ),
        if (store.canManageEvent(p) && secret?.passcode != null && !(secret?.personalCodes ?? false))
          _HostCodeCard(
            code: secret!.passcode!,
            onShare: () => shareFunkyPlace(context, p.name, when: p.startsAt == null ? null : dayLabel(p.startsAt!), code: secret.passcode),
          ),
        if (p.entryPrice != null)
          infoRow(Icons.payments_outlined, '${formatAmount(p.entryPrice!.toStringAsFixed(2))} to get in', 'Pay the host on Venmo or Cash App'),
      ],
      if (store.signedIn && !over && (priv ? store.canManageEvent(p) : true))
        infoRow(
          Icons.person_add_alt_1_outlined,
          'Invite friends',
          priv ? "They'll get in without the code" : 'Send them an invite right on FUNKY',
          onTap: () => showInviteFriendsSheet(context, p),
        ),
      if (isParty && insider)
        infoRow(
          Icons.forum_outlined,
          'Event chat',
          messageCount > 0
              ? (messageCount == 1 ? '1 message' : '$messageCount messages')
              : (isHost ? 'Answer questions and share the plan' : 'Ask the host anything, make plans'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventChatScreen(placeId: p.id))),
        ),
      if (p.eventType != null)
        infoRow(
          Icons.celebration_outlined,
          placeEventTypeLabel(p.eventType),
          null,
          lead: Text(placeEventTypeEmoji(p.eventType), textAlign: TextAlign.center, style: const TextStyle(fontSize: 22)),
        ),
      if (host != null)
        infoRow(
          Icons.storefront_outlined,
          'At ${host.name}',
          placeKindLabel(host.kind),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: host!.id))),
        ),
      if (!priv)
        infoRow(
          Icons.people_outline_rounded,
          place.going == 1 ? '1 going' : '${place.going} going',
          friendsGoing > 0 ? (friendsGoing == 1 ? '1 friend' : '$friendsGoing friends') : null,
          onTap: () => _showGoing(context, store, p),
        ),
      if (store.hasBeenTo(place.id))
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Builder(builder: (context) {
            final nights = store.nightsAt(place.id);
            return Row(
              children: [
                BeenHereBadge(size: 17, nights: nights),
                const SizedBox(width: 5),
                Text(
                  nights > 1 ? "You've been here $nights nights" : "You've been here",
                  style: TextStyle(color: tokens.friend, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ],
            );
          }),
        ),
      Padding(padding: const EdgeInsets.only(top: 4, bottom: 14), child: RatingSummaryLine(placeId: place.id, fontSize: 13)),
      // The owner's deal, for everyone.
      if (p.deal != null && p.deal!.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6, bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: tokens.orange.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              const Text('🎉', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("TONIGHT'S DEAL", style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.6)),
                    const SizedBox(height: 2),
                    Text(p.deal!, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 15)),
                  ],
                ),
              ),
            ],
          ),
        ),
      // Takes FUNKY reward passes.
      if (isVenue && (p.reward ?? '').isNotEmpty)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReferralScreen())),
          child: Container(
            margin: const EdgeInsets.only(top: 2, bottom: 8),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(color: tokens.gold.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                const Text('🎁', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('FUNKY REWARDS', style: TextStyle(color: tokens.gold, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.6)),
                      const SizedBox(height: 2),
                      Text(p.reward!, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                        (store.referral?.unusedRewards.isNotEmpty ?? false)
                            ? 'You have a pass — use it here'
                            : 'Invite 5 friends to FUNKY to get a pass',
                        style: TextStyle(color: tokens.mute, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: tokens.mute),
              ],
            ),
          ),
        ),
      // You run this place: your tools.
      if (isVenue && store.isPlaceOwner(p.id))
        _OwnerToolsCard(
          placeName: p.name,
          placeId: p.id,
          reward: p.reward,
          onEvent: () => showCreateSheet(context, eventAtPlaceId: p.id),
          onPhoto: () => _addPicture(store),
          onDeal: () => _editDeal(store, p),
          onReward: () => _editReward(store, p),
        )
      else if (isVenue && store.signedIn && !store.isGuest)
        Builder(builder: (context) {
          final status = store.myClaimStatus(p.id);
          if (status == 'pending') {
            return infoRow(Icons.hourglass_top_rounded, 'Your claim is being checked', "We'll let you know once it's approved.");
          }
          if (store.placeHasOwner(p.id)) return const SizedBox.shrink();
          return infoRow(
            Icons.storefront_rounded,
            'Own or manage this place?',
            'Claim it to post official events, add pictures and set deals',
            onTap: () => _claim(store, p),
          );
        }),
      if (isVenue && store.isAdmin && !store.isPlaceOwner(p.id))
        infoRow(
          Icons.card_giftcard_rounded,
          'FUNKY Rewards (Admin)',
          (p.reward ?? '').isEmpty ? 'Not taking passes — tap to set what they give' : '${p.reward} · tap to change',
          onTap: () => _editReward(store, p),
        ),
      if (hosted.isNotEmpty) ...[
        const SectionHeader(title: 'Coming up here'),
        for (final e in hosted)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: e.id))),
            child: FunkyCard(
              margin: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(placeEventTypeEmoji(e.eventType), style: const TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800))),
                            if (e.official) ...[
                              const SizedBox(width: 6),
                              const _OfficialChip(small: true),
                            ],
                          ],
                        ),
                        Text(
                          e.startsAt == null ? 'Tonight' : (store.isPlaceOnTonight(e) ? 'Tonight · ${clockLabel(e.startsAt!)}' : whenLabel(e.startsAt!)),
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
      ],
      _PicturePrompt(
        pending: store.myPendingPhotoPlaces.contains(place.id),
        uploading: _uploadingPhoto,
        hasPicture: place.photoUrl != null,
        isAdmin: store.isAdmin,
        signedIn: store.signedIn,
        onAdd: () => requireGuestOkThen(context, store, () => _addPicture(store)),
        onClear: () => store.clearPlacePhoto(place.id),
      ),
      // Posts tagged here, most liked first.
      Builder(builder: (context) {
        final here = store.rankPosts(store.postsAt(place.id));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: here.isEmpty ? 'Posts here' : 'Posts here (${here.length})',
              action: here.length > 6 ? 'See all' : 'Post',
              onAction: here.length > 6
                  ? () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PostsFeedScreen(placeId: place.id, title: 'Posts at ${place.name}'),
                      ))
                  : () => showCreateSheet(context, initial: CreateKind.post),
            ),
            if (here.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: EmptyNote(text: 'No posts tagged at ${place.name} yet. Make a post and tag this place.'),
              )
            else
              PostsGrid(posts: here.take(6).toList()),
          ],
        );
      }),
      if (!upcoming) PlaceRatingCard(placeId: place.id),
      const SizedBox(height: 14),
      FunkyCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // FUNKY Admin-verified gets the same checkmark as
                // crowd-verified, just in the brand orange instead of
                // gold, rather than a shield that read as a different
                // kind of badge entirely. Its own tap target explains
                // what the badge (or the not-yet-verified "?") means.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showVerifiedExplainer(context, isAdmin: venueAdminVerified, verified: venueVerified),
                  child: Icon(
                    venueVerified || venueAdminVerified ? Icons.verified : Icons.help_outline,
                    color: venueAdminVerified ? tokens.brand : (venueVerified ? tokens.gold : tokens.mute),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        venueAdminVerified ? 'FUNKY Verified' : (venueVerified ? 'Verified venue' : 'Is this venue real & active?'),
                        style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        venueAdminVerified
                            ? 'Verified by a FUNKY Admin · $venueConfirmations confirmations'
                            : '${venueVerified ? '' : 'Not admin verified · '}$venueConfirmations of ${AppStore.venueVerificationThreshold} confirmations',
                        style: TextStyle(color: tokens.mute, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: iConfirmedVenue
                      ? null
                      : () => requireGuestOkThen(context, store, () {
                            final error = store.confirmPlace(place.id);
                            if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                          }),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: iConfirmedVenue ? tokens.raised : tokens.brand,
                    disabledBackgroundColor: tokens.raised,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    iConfirmedVenue ? 'Confirmed ✓' : 'Confirm',
                    style: TextStyle(color: iConfirmedVenue ? tokens.ink : tokens.onOrange, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            // Only a signed-in FUNKY Admin (store.isAdmin — one
            // hardcoded account, see app_store.dart) ever sees this.
            if (store.isAdmin) ...[
              const Divider(height: 22),
              Row(
                children: [
                  Icon(Icons.admin_panel_settings, size: 18, color: tokens.brand),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'FUNKY Admin — skips the confirmation bar entirely',
                      style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => store.setAdminVerified(place.id, !venueAdminVerified),
                    child: Text(
                      venueAdminVerified ? 'Remove verification' : 'Verify as Admin',
                      style: TextStyle(color: venueAdminVerified ? tokens.danger : tokens.brand, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () async {
                    final to = await Navigator.of(context).push<LatLng>(
                      MaterialPageRoute(builder: (_) => MovePinScreen(title: 'Move ${place.name}', start: LatLng(place.place.lat, place.place.lng))),
                    );
                    if (to == null || !context.mounted) return;
                    final error = await store.adminMovePlace(place.id, to);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Pin moved.')));
                  },
                  icon: Icon(Icons.open_with_rounded, size: 18, color: tokens.brand),
                  label: Text('Move pin (Admin)', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => _confirmDeletePlace(context, store, place.name),
                  icon: Icon(Icons.delete_outline, size: 18, color: tokens.danger),
                  label: Text('Delete place (Admin)', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ],
        ),
      ),
      if (tonight) ...[
        const SizedBox(height: 14),
        FunkyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reports tonight', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                'Unverified until 8 different people confirm it — nobody can tell who reported or confirmed.',
                style: TextStyle(color: tokens.mute, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              // Cover charge has a typed detail ("$15"), so it gets its own
              // input row instead of the generic one-tap button below.
              _ReportTile(
                label: reports[ReportKind.cover]?.detail != null ? '${reports[ReportKind.cover]!.detail} cover' : 'Cover charge',
                report: reports[ReportKind.cover],
                onConfirm: (id) => _confirm(store, id),
                onRetract: (id) => _retract(store, id),
                trailing: Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _coverController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          hintText: '\$ amount',
                          hintStyle: TextStyle(color: tokens.mute),
                          filled: true,
                          fillColor: tokens.raised,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                        style: TextStyle(color: tokens.ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final amt = int.tryParse(_coverController.text);
                        if (amt == null || amt < 0) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a cover amount first')));
                          return;
                        }
                        _submit(store, ReportKind.cover, detail: '\$$amt');
                        _coverController.clear();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tokens.raised,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),
              _ReportTile(
                label: '🚨 Police',
                report: reports[ReportKind.police],
                onConfirm: (id) => _confirm(store, id),
                onRetract: (id) => _retract(store, id),
                trailing: ElevatedButton(
                  onPressed: () => _submit(store, ReportKind.police),
                  style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
              ),
              const Divider(height: 24),
              _ReportTile(
                label: 'Shut down',
                report: reports[ReportKind.shutdown],
                onConfirm: (id) => _confirm(store, id),
                onRetract: (id) => _retract(store, id),
                trailing: ElevatedButton(
                  onPressed: () => _submit(store, ReportKind.shutdown),
                  style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
              ),
              const Divider(height: 24),
              _ReportTile(
                label: reports[ReportKind.line]?.detail != null ? 'Line · ${reports[ReportKind.line]!.detail}' : 'Line / wait',
                report: reports[ReportKind.line],
                onConfirm: (id) => _confirm(store, id),
                onRetract: (id) => _retract(store, id),
                trailing: ElevatedButton(
                  onPressed: () => _submit(store, ReportKind.line, detail: '20 min'),
                  style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
              ),
              const Divider(height: 24),
              _ReportTile(
                label: 'At capacity',
                report: reports[ReportKind.capacity],
                onConfirm: (id) => _confirm(store, id),
                onRetract: (id) => _retract(store, id),
                trailing: ElevatedButton(
                  onPressed: () => _submit(store, ReportKind.capacity),
                  style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ],
    ];

    final memories = venueStories.isEmpty
        ? <Widget>[
            const SizedBox(height: 8),
            EmptyNote(
              text: over
                  ? 'This one is over. Stories from it live on as memories on the profiles of whoever posted them.'
                  : (upcoming ? 'Stories posted here show up once the night comes.' : 'No Stories here yet tonight. Post one here and everyone nearby sees it.'),
            ),
            if (tonight) ...[
              const SizedBox(height: 10),
              FunkyChip(label: 'Post a Story here', active: true, onPressed: () => showCreateSheet(context)),
            ],
          ]
        : <Widget>[
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 9 / 14,
              children: [
                for (final story in venueStories)
                  GestureDetector(
                    onTap: openStories,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: OrgBadgeCorner(
                        badge: storyOrgBadge(store, story),
                        small: true,
                        inset: 5,
                        child: storyMedia(story, tokens),
                      ),
                    ),
                  ),
              ],
            ),
          ];

    final rsvpButton = ElevatedButton.icon(
      onPressed: over ? null : () => locked ? _unlock(store, p) : _pickRsvp(store, p),
      icon: Icon(locked ? Icons.lock_open_rounded : (myRsvp == 'going' ? Icons.check_rounded : Icons.event_available_rounded), color: tokens.onOrange, size: 22),
      label: Text(
        over ? 'Over' : (locked ? 'Enter code' : (myRsvp == 'going' ? 'Going' : (myRsvp == 'maybe' ? 'Maybe' : (myRsvp == 'cant' ? "Can't go" : 'RSVP')))),
        style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 16),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: myRsvp == 'going' ? tokens.brand : tokens.orange,
        disabledBackgroundColor: tokens.raised,
        padding: const EdgeInsets.symmetric(vertical: 14),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    final goingButton = ElevatedButton.icon(
      onPressed: over ? null : () => _toggleGoing(store, p, upcoming: upcoming, going: going),
      icon: Icon(going ? Icons.check_rounded : Icons.add_rounded, color: going ? tokens.onOrange : tokens.onOrange, size: 22),
      label: Text(
        over ? 'Over' : (going ? 'Going' : "I'm going"),
        style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800, fontSize: 16),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: going ? tokens.brand : tokens.orange,
        disabledBackgroundColor: tokens.raised,
        padding: const EdgeInsets.symmetric(vertical: 14),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => priv
                ? shareFunkyPlace(context, p.name,
                    when: p.startsAt == null ? null : dayLabel(p.startsAt!), code: isHost ? secret?.passcode : null)
                : shareFunkyPlace(context, p.name, when: startsAt == null ? null : whenLabel(startsAt)),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(flex: 3, child: priv ? rsvpButton : goingButton),
              if (!locked) ...[
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: () => openDirections(context, p.lat, p.lng, p.name),
                  icon: Icon(Icons.near_me_outlined, color: tokens.ink, size: 20),
                  label: Text('Directions', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.raised,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              ],
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(p.name, style: TextStyle(color: tokens.ink, fontSize: 28, fontWeight: FontWeight.w900, height: 1.1)),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showVerifiedExplainer(context, isAdmin: venueAdminVerified, verified: venueVerified),
                child: Icon(
                  venueVerified || venueAdminVerified ? Icons.verified : Icons.help_outline,
                  color: venueAdminVerified ? tokens.brand : (venueVerified ? tokens.gold : tokens.mute),
                  size: 24,
                ),
              ),
            ],
          ),
          if (p.official || (isVenue && store.placeHasOwner(p.id)))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: p.official
                  ? Row(
                      children: [
                        const _OfficialChip(),
                        if (host != null) ...[
                          const SizedBox(width: 6),
                          Flexible(child: Text('Posted by ${host.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 13))),
                        ],
                      ],
                    )
                  : Row(
                      children: [
                        Icon(Icons.storefront_rounded, size: 16, color: tokens.brand),
                        const SizedBox(width: 5),
                        Text('Run by the owner on FUNKY', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700, fontSize: 13)),
                      ],
                    ),
            ),
          const SizedBox(height: 4),
          Text(
            locked
                ? (upcoming ? '🔒 Private · ${dayLabel(p.startsAt!)}' : '🔒 Private · tonight')
                : startsAt != null
                    ? (upcoming ? '${clockLabel(startsAt)} · ${nightsAwayLabel(p.night!)}' : clockLabel(startsAt))
                    : (p.eventType != null ? placeEventTypeLabel(p.eventType) : placeKindLabel(p.kind)),
            style: TextStyle(color: tokens.mute, fontSize: 21, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          if (!locked)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => priv ? _showGuests(context, store, p) : _showGoing(context, store, p),
            child: Row(
              children: [
                if (goingPeople.isNotEmpty)
                  SizedBox(
                    width: 30.0 * goingPeople.take(3).length + 14,
                    height: 44,
                    child: Stack(
                      children: [
                        for (var i = 0; i < goingPeople.take(3).length; i++)
                          Positioned(
                            left: 30.0 * i,
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.bg, width: 2)),
                              child: PersonAvatar(person: goingPeople[i], size: 40, preview: false),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: 40,
                    height: 40,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(color: tokens.raised, shape: BoxShape.circle),
                    child: Icon(Icons.people_outline_rounded, color: tokens.mute, size: 20),
                  ),
                const SizedBox(width: 4),
                Text(
                  priv
                      ? '$guestsGoing going${guestsMaybe > 0 ? ' · $guestsMaybe maybe' : ''}'
                      : (place.going == 1 ? '1 going' : '${place.going} going'),
                  style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 16),
                ),
                Icon(Icons.chevron_right_rounded, color: tokens.mute),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(onTap: venueStories.isEmpty ? null : openStories, child: art),
          const SizedBox(height: 14),
          _DetailTabs(index: _tab, memories: venueStories.length, onChanged: (i) => setState(() => _tab = i)),
          const SizedBox(height: 6),
          if (_tab == 1) ...memories else ...details,
        ],
      ),
    );
  }
}

/// "Details | Memories" — a two-way switch in a soft gray pill.
class _DetailTabs extends StatelessWidget {
  final int index;
  final int memories;
  final ValueChanged<int> onChanged;
  const _DetailTabs({required this.index, required this.memories, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    Widget seg(int i, String label) {
      final active = i == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? tokens.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              boxShadow: active ? const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))] : null,
            ),
            child: Text(
              label,
              style: TextStyle(color: active ? tokens.ink : tokens.mute, fontWeight: active ? FontWeight.w800 : FontWeight.w600, fontSize: 15),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(15)),
      child: Row(children: [seg(0, 'Details'), seg(1, memories > 0 ? 'Memories ($memories)' : 'Memories')]),
    );
  }
}

/// One report kind's current state: the label, the verified/unverified
/// status line with its real confirmation count, a big Confirm/Confirmed✓
/// button when there's an active report, and a "report it fresh" control
/// (a text input + button for cover, a plain button for everything else)
/// passed in as [trailing].
class _ReportTile extends StatelessWidget {
  final String label;
  final PlaceReport? report;
  final void Function(String reportId) onConfirm;
  final void Function(String reportId) onRetract;
  final Widget trailing;
  const _ReportTile({required this.label, required this.report, required this.onConfirm, required this.onRetract, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final r = report;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 6),
        if (r == null)
          Text('No report yet tonight.', style: TextStyle(color: tokens.mute, fontSize: 12.5))
        else
          Row(
            children: [
              Icon(
                r.verified ? Icons.verified : Icons.warning_amber_rounded,
                size: 16,
                color: r.verified ? tokens.gold : tokens.mute,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  r.verified
                      ? '✓ VERIFIED · Confirmed by ${r.confirmations} ${r.confirmations == 1 ? 'person' : 'people'}'
                      : '⚠️ UNVERIFIED · Confirmed by ${r.confirmations} ${r.confirmations == 1 ? 'person' : 'people'}',
                  style: TextStyle(
                    color: r.verified ? tokens.gold : tokens.mute,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        if (r != null) ...[
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              onPressed: r.confirmedBy.contains('me') ? null : () => onConfirm(r.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: r.confirmedBy.contains('me') ? tokens.raised : tokens.brand,
                disabledBackgroundColor: tokens.raised,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                r.confirmedBy.contains('me') ? 'Confirmed ✓' : 'Confirm',
                style: TextStyle(
                  color: r.confirmedBy.contains('me') ? tokens.ink : tokens.onOrange,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ] else
          const SizedBox(height: 4),
        // Lets you undo a report you submitted by accident — only ever
        // shown to the person who actually posted it, never to whoever's
        // just confirming someone else's.
        if (r != null && r.reporterId == 'me')
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => onRetract(r.id),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
              child: Text('Remove my report', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600, fontSize: 12.5)),
            ),
          ),
        trailing,
      ],
    );
  }
}

/// "Add a picture" under the place's details — anyone can suggest one, an
/// admin approves it.
class _PicturePrompt extends StatelessWidget {
  final bool pending;
  final bool uploading;
  final bool hasPicture;
  final bool isAdmin;
  final bool signedIn;
  final VoidCallback onAdd;
  final VoidCallback onClear;
  const _PicturePrompt({
    required this.pending,
    required this.uploading,
    required this.hasPicture,
    required this.isAdmin,
    required this.signedIn,
    required this.onAdd,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pending)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Your picture is waiting to be verified by a FUNKY admin. You get 1,000 Funky Points once it is.',
                style: TextStyle(color: tokens.mute, fontSize: 12.5),
              ),
            ),
          Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: uploading ? null : onAdd,
              icon: uploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                  : Icon(Icons.add_a_photo_outlined, size: 18, color: tokens.ink),
              label: Text(
                uploading
                    ? 'Uploading…'
                    : isAdmin
                        ? (hasPicture ? 'Change the picture' : 'Add a picture')
                        : (hasPicture ? 'Suggest a new picture · 1,000 pts' : 'Upload a verified picture · 1,000 pts'),
                style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: tokens.line),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          if (isAdmin && hasPicture)
            TextButton(onPressed: onClear, child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700))),
        ],
          ),
          // The reward for a good picture of the place.
          if (!isAdmin)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.stars_rounded, size: 16, color: tokens.orange),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      signedIn
                          ? 'Upload a verified picture for 1,000 Funky Points. A FUNKY admin checks every picture before it shows, and you get the points once it\'s verified. Use your own photo.'
                          : 'Log in to upload a verified picture for 1,000 Funky Points.',
                      style: TextStyle(color: tokens.mute, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What someone without the code sees on a private event.
class _PrivateLockCard extends StatelessWidget {
  final String night;
  final bool signedIn;
  final VoidCallback onUnlock;
  final VoidCallback onAsk;
  final double? price;
  // Your request to go: 'asked', 'pay_sent', 'paid', 'in', 'declined', or null.
  final String? requestStatus;
  final GoingPreview? preview;
  const _PrivateLockCard({
    required this.night,
    required this.signedIn,
    required this.onUnlock,
    required this.onAsk,
    this.price,
    this.requestStatus,
    this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final faces = [
      for (final f in preview?.faces ?? const <String>[])
        if (store.personById(f) case final person?) person,
    ];
    final count = preview?.count;
    final asked = requestStatus != null && requestStatus != 'declined';
    final askLabel = switch (requestStatus) {
      'asked' => 'Asked · open chat with the host',
      'pay_sent' => 'The host sent how to pay · open chat',
      'paid' => 'You paid · waiting to be let in',
      'declined' => "The host can't fit you in",
      _ => 'Ask to go',
    };
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(Icons.lock_rounded, color: tokens.brand, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Private event · $night', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                    const SizedBox(height: 2),
                    Text(
                      price != null ? '${formatAmount(price!.toStringAsFixed(2))} to get in · address and time for guests only' : 'Address and time are for guests only.',
                      style: TextStyle(color: tokens.mute, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (faces.isNotEmpty || count != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (faces.isNotEmpty)
                  SizedBox(
                    width: 18.0 * faces.length + 10,
                    height: 26,
                    child: Stack(
                      children: [
                        for (var i = 0; i < faces.length; i++)
                          Positioned(
                            left: 18.0 * i,
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.raised, width: 2)),
                              child: PersonAvatar(person: faces[i], size: 24, preview: false),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (faces.isNotEmpty) const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    count != null
                        ? '$count going${faces.isNotEmpty ? ', including friends' : ''}'
                        : (faces.length == 1 ? '@${faces.first.handle} is going' : 'Friends are going${preview?.more == true ? ' · and more' : ''}'),
                    style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            signedIn
                ? 'Have a code from the host? Enter it. No code? Ask to go — the host gets it in their messages.'
                : 'Make an account, then enter the code from the host or ask to go.',
            style: TextStyle(color: tokens.ink, fontSize: 13.5, height: 1.35),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onUnlock,
                  icon: Icon(Icons.lock_open_rounded, color: tokens.onOrange, size: 19),
                  label: Text(signedIn ? 'Enter code' : 'Make an account', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.orange,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (signedIn) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: requestStatus == 'declined' ? null : onAsk,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: asked ? tokens.friend : tokens.line),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      askLabel,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(color: asked ? tokens.friend : tokens.ink, fontWeight: FontWeight.w800, fontSize: asked ? 12 : 14),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// For the host, co-hosts and door staff: requests, codes, the door, the team.
class _RunEventCard extends StatelessWidget {
  final String role;
  final int openRequests;
  final int checkedIn;
  final int onList;
  final ValueChanged<int> onOpen;
  const _RunEventCard({required this.role, required this.openRequests, required this.checkedIn, required this.onList, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final manage = role == 'host' || role == 'cohost';
    Widget tool(IconData icon, String label, int tab, {int badge = 0}) => Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onOpen(manage ? tab : 0),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: tokens.line)),
              child: Column(
                children: [
                  Badge(
                    isLabelVisible: badge > 0,
                    label: Text('$badge'),
                    backgroundColor: tokens.danger,
                    child: Icon(icon, color: tokens.brand, size: 22),
                  ),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ],
              ),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, color: tokens.brand, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  role == 'host' ? 'Run your event' : role == 'cohost' ? "You're a co-host" : "You're on the door",
                  style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              Text('$checkedIn/$onList in', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (manage) ...[
                tool(Icons.front_hand_outlined, 'Requests', 0, badge: openRequests),
                const SizedBox(width: 8),
                tool(Icons.key_rounded, 'Codes', 1),
                const SizedBox(width: 8),
              ],
              tool(Icons.door_front_door_outlined, 'Door', 2),
              if (manage) ...[
                const SizedBox(width: 8),
                tool(Icons.group_outlined, 'Team', 3),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Going · Maybe · Can't go, with how many said each, and the guest list.
class _RsvpCard extends StatelessWidget {
  final String? status;
  // "12 going · see the guest list", or the hint when the host hides the count.
  final String summary;
  // When the host hides the count: a few faces going.
  final List<Person> faces;
  final ValueChanged<String> onPick;
  final VoidCallback? onGuests;
  const _RsvpCard({required this.status, required this.summary, this.faces = const [], required this.onPick, required this.onGuests});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    Widget option(String value, String label, IconData icon) {
      final on = status == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onPick(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? tokens.brand : tokens.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? tokens.brand : tokens.line),
            ),
            child: Column(
              children: [
                Icon(icon, size: 20, color: on ? tokens.onOrange : tokens.ink),
                const SizedBox(height: 3),
                Text(label, style: TextStyle(color: on ? tokens.onOrange : tokens.ink, fontWeight: FontWeight.w800, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status == null || status == 'unlocked' ? 'Are you going?' : 'Your RSVP', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 10),
          Row(
            children: [
              option('going', 'Going', Icons.check_circle_outline_rounded),
              const SizedBox(width: 8),
              option('maybe', 'Maybe', Icons.help_outline_rounded),
              const SizedBox(width: 8),
              option('cant', "Can't go", Icons.cancel_outlined),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onGuests,
            child: Row(
              children: [
                if (faces.isEmpty)
                  Icon(Icons.people_outline_rounded, color: tokens.mute, size: 19)
                else
                  SizedBox(
                    width: 16.0 * faces.length + 8,
                    height: 24,
                    child: Stack(
                      children: [
                        for (var i = 0; i < faces.length; i++)
                          Positioned(
                            left: 16.0 * i,
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.raised, width: 1.5)),
                              child: PersonAvatar(person: faces[i], size: 22, preview: false),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(summary, style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                if (onGuests != null) Icon(Icons.chevron_right_rounded, color: tokens.mute),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The host's code, to copy or send to people.
class _HostCodeCard extends StatelessWidget {
  final String code;
  final VoidCallback onShare;
  const _HostCodeCard({required this.code, required this.onShare});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(Icons.key_rounded, color: tokens.brand, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your code', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(code, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 3)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied.')));
            },
            icon: Icon(Icons.copy_rounded, color: tokens.ink, size: 21),
          ),
          IconButton(
            tooltip: 'Send invite',
            onPressed: onShare,
            icon: Icon(Icons.ios_share_rounded, color: tokens.ink, size: 21),
          ),
        ],
      ),
    );
  }
}

/// "✓ Official" — posted by the bar or club's owner.
class _OfficialChip extends StatelessWidget {
  final bool small;
  const _OfficialChip({this.small = false});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 1 : 3),
      decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: small ? 12 : 14, color: tokens.brand),
          const SizedBox(width: 3),
          Text('Official', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800, fontSize: small ? 10.5 : 12.5)),
        ],
      ),
    );
  }
}

/// What the owner of a bar or club sees on its page.
class _OwnerToolsCard extends StatefulWidget {
  final String placeName;
  final String placeId;
  final String? reward;
  final VoidCallback onEvent;
  final VoidCallback onPhoto;
  final VoidCallback onDeal;
  final VoidCallback onReward;
  const _OwnerToolsCard({
    required this.placeName,
    required this.placeId,
    required this.reward,
    required this.onEvent,
    required this.onPhoto,
    required this.onDeal,
    required this.onReward,
  });

  @override
  State<_OwnerToolsCard> createState() => _OwnerToolsCardState();
}

class _OwnerToolsCardState extends State<_OwnerToolsCard> {
  int? _used;

  @override
  void initState() {
    super.initState();
    context.read<AppStore>().rewardsUsedAt(widget.placeId).then((n) {
      if (mounted) setState(() => _used = n);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final reward = widget.reward ?? '';
    Widget tool(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: tokens.line)),
              child: Column(
                children: [
                  Icon(icon, color: tokens.brand, size: 22),
                  const SizedBox(height: 4),
                  Text(label, textAlign: TextAlign.center, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ],
              ),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storefront_rounded, color: tokens.brand, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('You run ${widget.placeName}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15))),
            ],
          ),
          const SizedBox(height: 4),
          Text('Your events go up as Official and verified right away. Your pictures go live with no wait.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
          const SizedBox(height: 12),
          Row(
            children: [
              tool(Icons.event_available_rounded, 'Post an event', widget.onEvent),
              const SizedBox(width: 8),
              tool(Icons.add_a_photo_outlined, 'Add pictures', widget.onPhoto),
              const SizedBox(width: 8),
              tool(Icons.local_offer_outlined, 'Set a deal', widget.onDeal),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onReward,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: tokens.line)),
              child: Row(
                children: [
                  const Text('🎁', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reward.isEmpty ? 'Take FUNKY reward passes' : 'FUNKY Rewards: $reward',
                          style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 13.5),
                        ),
                        Text(
                          reward.isEmpty
                              ? 'People who bring 5 friends onto FUNKY come here to use their pass'
                              : '${_used ?? 0} used here so far · tap to change',
                          style: TextStyle(color: tokens.mute, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: tokens.mute),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
