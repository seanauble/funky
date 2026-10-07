import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../widgets/place_rating_card.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'place_story_viewer_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    RankedPlace? found;
    for (final p in store.rankedPlaces) {
      if (p.id == widget.placeId) {
        found = p;
        break;
      }
    }

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
    final going = store.me.move == place.id;
    final reports = store.reportsFor(place.id);
    final venueStories = store.storiesFor(place.id);
    final latestVenueStory = store.latestMediaStoryFor(place.id);
    final venueVerified = store.isPlaceVerified(place.id);
    final venueAdminVerified = store.isAdminVerified(place.id);
    final venueConfirmations = store.venueConfirmationCount(place.id);
    final iConfirmedVenue = store.hasConfirmedPlace(place.id);

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(place.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          GestureDetector(
            onTap: venueStories.isEmpty
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PlaceStoryViewerScreen(placeId: place.id, placeName: place.name)),
                    ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 160,
                width: double.infinity,
                child: Stack(
                alignment: Alignment.center,
                children: [
                  // Switches from the flat colored-letter box to a looping
                  // preview of the latest photo/video posted here the
                  // moment someone posts a Story at this place.
                  Positioned.fill(
                    child: PlaceMediaThumbnail(story: latestVenueStory, coverPhotoPath: place.coverPhotoPath, coverUrl: place.coverUrl, photoUrl: place.photoUrl, fallbackLabel: place.name.substring(0, 1), fontSize: 40),
                  ),
                  if (venueStories.isNotEmpty)
                    Positioned(
                      bottom: 10,
                      right: 12,
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
                ],
              ),
            ),
          ),
          ),
          const SizedBox(height: 14),
          Text(place.name, style: TextStyle(color: tokens.ink, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${place.address} · ${formatMiles(place.distance)}', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 6),
          RatingSummaryLine(placeId: place.id, fontSize: 13),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => store.setMove(going ? 'in' : place.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: going ? tokens.raised : tokens.brand,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                going ? "You're going ✓" : "I'm going",
                style: TextStyle(color: going ? tokens.ink : tokens.onOrange, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('🔥 ${place.going} going tonight', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 20),
          _PicturePrompt(
            pending: store.myPendingPhotoPlaces.contains(place.id),
            uploading: _uploadingPhoto,
            hasPicture: place.photoUrl != null,
            isAdmin: store.isAdmin,
            onAdd: () => requireAccountThen(context, store, () => _addPicture(store)),
            onClear: () => store.clearPlacePhoto(place.id),
          ),
          PlaceRatingCard(placeId: place.id),
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
                          : () => requireAccountThen(context, store, () {
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
                      onPressed: () => _confirmDeletePlace(context, store, place.name),
                      icon: Icon(Icons.delete_outline, size: 18, color: tokens.danger),
                      label: Text('Delete place (Admin)', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ],
            ),
          ),
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
      ),
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
  final VoidCallback onAdd;
  final VoidCallback onClear;
  const _PicturePrompt({
    required this.pending,
    required this.uploading,
    required this.hasPicture,
    required this.isAdmin,
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
                'Your picture is waiting for admin approval.',
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
                uploading ? 'Uploading…' : (hasPicture ? 'Suggest a new picture' : 'Add a picture'),
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
        ],
      ),
    );
  }
}
