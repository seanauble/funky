import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
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
      if (mounted) context.read<AppStore>().fetchPostsAt(widget.placeId);
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
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: tokens.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: tokens.ink),
              title: Text('Choose from library', style: TextStyle(color: tokens.ink)),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: tokens.ink),
              title: Text('Take a photo', style: TextStyle(color: tokens.ink)),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
          ],
        ),
      ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
    final startsAt = p.startsAt;
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
    final goingPeople = store.peopleGoingToPlace(p.id);
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
    final details = <Widget>[
      infoRow(
        Icons.location_on_outlined,
        address,
        '${placeKindLabel(p.kind)} · ${place.distance < 0.1 ? 'right by you' : '${formatMiles(place.distance)} away'}',
        onTap: () => openDirections(context, p.lat, p.lng, p.name),
      ),
      if (startsAt != null)
        infoRow(Icons.schedule_rounded, clockLabel(startsAt), '${dayLabel(startsAt)} · ${partOfNightLabel(startsAt)}'),
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
                        Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
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
            onPressed: () => shareFunkyPlace(context, p.name, when: startsAt == null ? null : whenLabel(startsAt)),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(flex: 3, child: goingButton),
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
          const SizedBox(height: 4),
          Text(
            startsAt != null
                ? (upcoming ? '${clockLabel(startsAt)} · ${nightsAwayLabel(p.night!)}' : clockLabel(startsAt))
                : (p.eventType != null ? placeEventTypeLabel(p.eventType) : placeKindLabel(p.kind)),
            style: TextStyle(color: tokens.mute, fontSize: 21, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showGoing(context, store, p),
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
                  place.going == 1 ? '1 going' : '${place.going} going',
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
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
