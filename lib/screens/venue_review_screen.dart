import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/venue_models.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';

/// Admin → New venues: every bar, pub and club within 50 miles of Egg Harbor
/// from OpenStreetMap (free). Add a photo, then approve (it goes live as a
/// FUNKY-verified place), deny, or edit — rename it, fix the address, switch
/// bar/club, leave a note — and come back to it later.
class VenueReviewScreen extends StatefulWidget {
  const VenueReviewScreen({super.key});

  @override
  State<VenueReviewScreen> createState() => _VenueReviewScreenState();
}

class _VenueReviewScreenState extends State<VenueReviewScreen> {
  String _filter = 'pending';
  bool _importing = false;
  final Set<String> _busy = {};

  static const _filters = [
    ('pending', 'To review'),
    ('changes', 'Needs changes'),
    ('approved', 'Approved'),
    ('denied', 'Denied'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStore>().fetchVenueCandidates();
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import(AppStore store) async {
    setState(() => _importing = true);
    final message = await store.importVenues();
    if (!mounted) return;
    setState(() => _importing = false);
    _toast(message);
  }

  Future<void> _decide(AppStore store, VenueCandidate v, String decision, {String? note, String? name, String? kind, int? photoIndex, String? address}) async {
    setState(() => _busy.add(v.id));
    final error = await store.reviewVenue(v.id, decision, note: note, name: name, kind: kind, photoIndex: photoIndex, address: address);
    if (!mounted) return;
    setState(() => _busy.remove(v.id));
    if (error != null) {
      _toast(error);
    } else if (decision == 'approve') {
      _toast('${name ?? v.name} is live on the map.');
    }
  }

  Future<void> _addPhoto(AppStore store, VenueCandidate v) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).extension<FunkyTokens>()!.tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
    if (picked == null || !mounted) return;
    setState(() => _busy.add(v.id));
    final error = await store.setVenuePhoto(v.id, picked.path);
    if (!mounted) return;
    setState(() => _busy.remove(v.id));
    _toast(error ?? 'Photo added.');
  }

  Future<void> _edit(AppStore store, VenueCandidate v) async {
    final result = await showModalBottomSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).extension<FunkyTokens>()!.tokens.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _EditSheet(venue: v),
    );
    if (result == null || !mounted) return;
    await _decide(store, v, result.decision, note: result.note, name: result.name, kind: result.kind, photoIndex: result.photoIndex, address: result.address);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final all = store.venueCandidates;
    final shown = all.where((v) => v.status == _filter).toList();
    int count(String s) => all.where((v) => v.status == s).length;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('New venues')),
      body: RefreshIndicator(
        onRefresh: store.fetchVenueCandidates,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            FunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bars & clubs within 50 miles of Egg Harbor', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    'Pulls every bar, pub and nightclub from OpenStreetMap (free). Add your own photo to each, fix anything that\'s off, then approve. Safe to run again — it only adds ones you haven\'t seen.',
                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _importing ? null : () => _import(store),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tokens.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: _importing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.cloud_download_outlined, size: 18),
                      label: Text(_importing ? 'Importing… (up to a minute)' : 'Import bars & clubs'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (key, label) in _filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FunkyChip(label: '$label (${count(key)})', active: _filter == key, onPressed: () => setState(() => _filter = key)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (!store.venueCandidatesLoaded)
              const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
            else if (shown.isEmpty)
              EmptyNote(
                text: all.isEmpty
                    ? 'Nothing imported yet. Tap "Import bars & clubs".'
                    : 'Nothing here.',
              )
            else
              for (final v in shown)
                _VenueCard(
                  venue: v,
                  busy: _busy.contains(v.id),
                  onApprove: () => _decide(store, v, 'approve'),
                  onDeny: () => _decide(store, v, 'deny'),
                  onEdit: () => _edit(store, v),
                  onUndo: () => _decide(store, v, 'pending'),
                  onAddPhoto: () => _addPhoto(store, v),
                ),
            const SizedBox(height: 10),
            Text('Venue list © OpenStreetMap contributors', textAlign: TextAlign.center, style: TextStyle(color: tokens.mute, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _VenueCard extends StatelessWidget {
  final VenueCandidate venue;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final VoidCallback onEdit;
  final VoidCallback onUndo;
  final VoidCallback onAddPhoto;
  const _VenueCard({
    required this.venue,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
    required this.onEdit,
    required this.onUndo,
    required this.onAddPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.read<AppStore>();
    final photo = venue.photo;
    final point = ll.LatLng(venue.lat, venue.lng);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: tokens.line)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 170,
            width: double.infinity,
            child: venue.customPhotoUrl != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        venue.customPhotoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(color: tokens.raised),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: GestureDetector(
                          onTap: busy ? null : onAddPhoto,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.photo_camera_outlined, color: Colors.white, size: 15),
                                SizedBox(width: 4),
                                Text('Change', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : photo == null
                ? InkWell(
                    onTap: busy ? null : onAddPhoto,
                    child: Container(
                      color: tokens.raised,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_a_photo_outlined, color: tokens.brand, size: 30),
                          const SizedBox(height: 6),
                          Text('Add a photo', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        store.venuePhotoUrl(photo.ref),
                        fit: BoxFit.cover,
                        loadingBuilder: (_, child, progress) =>
                            progress == null ? child : Container(color: tokens.raised, alignment: Alignment.center, child: const CircularProgressIndicator(strokeWidth: 2)),
                        errorBuilder: (_, __, ___) => Container(
                          color: tokens.raised,
                          alignment: Alignment.center,
                          child: Text("Photo didn't load", style: TextStyle(color: tokens.mute)),
                        ),
                      ),
                      if (photo.credit != null)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                            child: Text('Photo: ${photo.credit} · Google', style: const TextStyle(color: Colors.white, fontSize: 10)),
                          ),
                        ),
                      if (venue.photos.length > 1)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                            child: Text('${venue.photoIndex + 1}/${venue.photos.length} photos', style: const TextStyle(color: Colors.white, fontSize: 10)),
                          ),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(venue.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(
                        venue.address.isEmpty ? 'No street address on file — add one in Edit' : venue.address,
                        style: TextStyle(color: tokens.mute, fontSize: 12.5, fontStyle: venue.address.isEmpty ? FontStyle.italic : FontStyle.normal),
                      ),
                      if (venue.distanceMiles != null)
                        Text('${venue.distanceMiles!.toStringAsFixed(1)} mi from Egg Harbor', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(8)),
                  child: Text(venue.kind == 'club' ? 'Club' : 'Bar', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ],
            ),
          ),
          if (venue.note != null && venue.note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: tokens.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Text('📝 ${venue.note}', style: TextStyle(color: tokens.ink, fontSize: 12.5)),
              ),
            ),
          // Where it is.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 110,
                child: IgnorePointer(
                  child: FlutterMap(
                    options: MapOptions(initialCenter: point, initialZoom: 14.5),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.funkyapp.funky',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: point,
                            width: 30,
                            height: 30,
                            child: Icon(Icons.location_on, color: tokens.brand, size: 30),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: busy
                ? const Center(child: Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2)))
                : _actions(context, tokens),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, ThemeTokens tokens) {
    if (venue.status == 'approved') {
      return Row(
        children: [
          Icon(Icons.verified, color: tokens.gold, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text('Live on the map', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
          if (venue.placeId != null)
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: venue.placeId!))),
              child: Text('Open', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
            ),
          TextButton(onPressed: onEdit, child: Text('Edit', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w700))),
        ],
      );
    }
    if (venue.status == 'denied') {
      return Row(
        children: [
          Expanded(child: Text('Denied', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700))),
          TextButton(onPressed: onUndo, child: Text('Move back to review', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700))),
        ],
      );
    }
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: onApprove,
            style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, foregroundColor: Colors.white, elevation: 0, shape: shape),
            child: const Text('Approve', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: onEdit,
            style: OutlinedButton.styleFrom(foregroundColor: tokens.ink, side: BorderSide(color: tokens.line), shape: shape),
            child: const Text('Edit / note', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: onDeny,
            style: OutlinedButton.styleFrom(foregroundColor: tokens.danger, side: BorderSide(color: tokens.line), shape: shape),
            child: const Text('Deny', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

class _EditResult {
  final String decision;
  final String? note;
  final String? name;
  final String? kind;
  final int? photoIndex;
  final String? address;
  const _EditResult(this.decision, {this.note, this.name, this.kind, this.photoIndex, this.address});
}

/// Rename, switch bar/club, swipe through Google's photos to pick the best
/// one, leave a note — then approve, or save it under "Needs changes".
class _EditSheet extends StatefulWidget {
  final VenueCandidate venue;
  const _EditSheet({required this.venue});

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.venue.name);
  late final TextEditingController _note = TextEditingController(text: widget.venue.note ?? '');
  late final TextEditingController _address = TextEditingController(text: widget.venue.address);
  late String _kind = widget.venue.kind;
  late int _photo = widget.venue.photoIndex;
  late final PageController _pages = PageController(initialPage: widget.venue.photoIndex, viewportFraction: 0.86);

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _address.dispose();
    _pages.dispose();
    super.dispose();
  }

  _EditResult _result(String decision) => _EditResult(
        decision,
        note: _note.text.trim(),
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        kind: _kind,
        photoIndex: _photo,
        address: _address.text.trim(),
      );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.read<AppStore>();
    final photos = widget.venue.photos;
    InputDecoration field(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: tokens.mute),
          filled: true,
          fillColor: tokens.bg,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: tokens.line)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: tokens.line)),
        );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Edit venue', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 12),
              if (photos.isNotEmpty) ...[
                Text('Pick a photo (swipe)', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 160,
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: photos.length,
                    onPageChanged: (i) => setState(() => _photo = i),
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.network(store.venuePhotoUrl(photos[i].ref, width: 600), fit: BoxFit.cover),
                            if (i == _photo)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Icon(Icons.check_circle, color: tokens.brand, size: 26, shadows: const [Shadow(blurRadius: 4, color: Colors.black54)]),
                              ),
                            if (photos[i].credit != null)
                              Positioned(
                                left: 6,
                                bottom: 6,
                                child: Text('Photo: ${photos[i].credit} · Google',
                                    style: const TextStyle(color: Colors.white, fontSize: 10, shadows: [Shadow(blurRadius: 4, color: Colors.black)])),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text('Name', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(controller: _name, maxLength: 40, style: TextStyle(color: tokens.ink), decoration: field('Venue name')),
              Text('Address', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(controller: _address, maxLength: 80, style: TextStyle(color: tokens.ink), decoration: field('Street, town')),
              Row(
                children: [
                  for (final k in const ['bar', 'club'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FunkyChip(label: k == 'bar' ? 'Bar' : 'Club', active: _kind == k, onPressed: () => setState(() => _kind = k)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Note (what needs changing)', style: TextStyle(color: tokens.mute, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(controller: _note, maxLines: 3, minLines: 2, style: TextStyle(color: tokens.ink), decoration: field('e.g. closed on weekdays, wrong photo')),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(_result('changes')),
                      style: OutlinedButton.styleFrom(foregroundColor: tokens.ink, side: BorderSide(color: tokens.line)),
                      child: const Text('Save for later'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(_result('approve')),
                      style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, foregroundColor: Colors.white, elevation: 0),
                      child: const Text('Save & approve', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
