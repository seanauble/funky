import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';

const _heatLabel = ['Quiet so far', 'Some activity', 'Active', 'Very active'];

// The app-wide 25-mile area, in meters, and the lat/lng box that just
// contains that circle (used to frame the map).
const double _radiusMeters = 25 * 1609.344;

LatLngBounds _radiusBounds(double lat, double lng) {
  const milesPerDegLat = 69.0;
  final dLat = 25 / milesPerDegLat;
  final cosLat = math.cos(lat * math.pi / 180).abs();
  final dLng = 25 / (milesPerDegLat * (cosLat < 0.05 ? 0.05 : cosLat));
  return LatLngBounds(ll.LatLng(lat - dLat, lng - dLng), ll.LatLng(lat + dLat, lng + dLng));
}

/// The little text box explaining what a verified checkmark on a place
/// means — its own tap target, separate from the row/marker, which opens
/// the place instead.
void _showVerifiedExplainer(BuildContext context, {required bool isAdmin}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        isAdmin
            ? 'FUNKY Verified — confirmed legit by the FUNKY team.'
            : 'FUNKY Verified — confirmed legit by the FUNKY community (15+ confirmations).',
      ),
      duration: const Duration(seconds: 3),
    ),
  );
}

class PlacesScreen extends StatelessWidget {
  const PlacesScreen({super.key});

  void _openPlace(BuildContext context, String placeId) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: placeId)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (store.location == null) return const LocationGate();

    final here = store.location!;
    final ranked = store.rankedPlaces;
    // A looping video preview per row is heavy, so only the first few
    // places whose latest Story is a video get one; the rest show their
    // picture instead.
    bool isVideoStory(Story? st) => st != null && (st.videoPath != null || st.videoUrl != null);
    final videoRows = <String>{};
    for (final rp in ranked) {
      if (videoRows.length >= 6) break;
      if (isVideoStory(store.latestMediaStoryFor(rp.id))) videoRows.add(rp.id);
    }
    var markerVideoBudget = 6;
    final maxScore = ranked.isEmpty ? 1 : ranked.map((p) => p.score).reduce((a, b) => a > b ? a : b).clamp(1, 999999);

    return Scaffold(
      backgroundColor: tokens.bg,
      body: Column(
        children: [
          Container(
            height: 240,
            width: double.infinity,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.mapLine))),
            child: Stack(
              children: [
                FlutterMap(
                  // A fresh map when your location changes (e.g. the real GPS
                  // fix replacing the default), since the starting view below
                  // is only read once.
                  key: ValueKey('${here.lat.toStringAsFixed(2)},${here.lng.toStringAsFixed(2)}'),
                  options: MapOptions(
                    initialCenter: ll.LatLng(here.lat, here.lng),
                    // Starts zoomed out just far enough to show the whole
                    // 25-mile circle.
                    initialCameraFit: CameraFit.bounds(
                      bounds: _radiusBounds(here.lat, here.lng),
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.funkyapp.funky',
                    ),
                    // The 25-mile radius — everything FUNKY shows you
                    // (places, polls, chat, Stories) comes from inside it.
                    CircleLayer(
                      circles: [
                        CircleMarker(
                          point: ll.LatLng(here.lat, here.lng),
                          radius: _radiusMeters,
                          useRadiusInMeter: true,
                          color: tokens.orange.withValues(alpha: 0.07),
                          borderColor: tokens.orange.withValues(alpha: 0.85),
                          borderStrokeWidth: 2,
                        ),
                      ],
                    ),
                    // Hand-rolled soft heat-glow: a blurred, radially-gradiented
                    // circle under each place, sized/opacity-scaled by that
                    // place's activity score. No third-party heatmap plugin —
                    // just flutter_map + core Flutter blur/gradient APIs, so
                    // there's no dependency risk to the iOS/Android build.
                    if (ranked.isNotEmpty)
                      MarkerLayer(
                        markers: ranked.map((p) {
                          final intensity = (p.score / maxScore).clamp(0.08, 1.0);
                          final size = 60.0 + intensity * 90.0;
                          final glowColor = tokens.orange;
                          return Marker(
                            point: ll.LatLng(p.place.lat, p.place.lng),
                            width: size,
                            height: size,
                            child: IgnorePointer(
                              child: ImageFiltered(
                                imageFilter: ui.ImageFilter.blur(sigmaX: size / 6, sigmaY: size / 6),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        glowColor.withValues(alpha: 0.55 * intensity),
                                        glowColor.withValues(alpha: 0.0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: ll.LatLng(here.lat, here.lng),
                          width: 20,
                          height: 20,
                          child: Container(
                            decoration: BoxDecoration(
                              color: tokens.you,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                        ...ranked.map((p) {
                          const size = 38.0;
                          final story = store.latestMediaStoryFor(p.id);
                          // A video frame is the last resort (it spins up a
                          // player), so only a handful of pins get one.
                          final needsVideo = p.photoUrl == null &&
                              p.coverPhotoPath == null &&
                              p.coverUrl == null &&
                              story?.imagePath == null &&
                              story?.imageUrl == null &&
                              isVideoStory(story);
                          final allowVideo = needsVideo && markerVideoBudget-- > 0;
                          return Marker(
                            point: ll.LatLng(p.place.lat, p.place.lng),
                            width: size,
                            height: size,
                            child: GestureDetector(
                              onTap: () => _openPlace(context, p.id),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: tokens.orange,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: ClipOval(
                                  child: SizedBox(
                                    width: size,
                                    height: size,
                                    child: _MarkerPicture(place: p, story: story, allowVideo: allowVideo),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(999)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.orange, width: 2)),
                        ),
                        const SizedBox(width: 6),
                        Text('25-mile radius', style: TextStyle(color: tokens.ink, fontSize: 11, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
                if (ranked.isEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        'Nothing listed near you yet — the glow fills in once places get votes and Stories.',
                        style: TextStyle(color: tokens.mute, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (store.rankedPlaces.isEmpty)
                  const EmptyNote(text: 'Nothing is listed within 25 miles yet. Be the first to add one.')
                else
                  ...store.rankedPlaces.map((p) {
                    final bits = <String>[placeKindLabel(p.kind)];
                    if (p.going > 0) {
                      bits.add('🔥 ${p.going} going');
                    } else if (p.heat == 0) {
                      bits.add('Be the first to check in');
                    }
                    if (p.heat > 0) bits.add(_heatLabel[p.heat]);
                    final shut = p.reports[ReportKind.shutdown];
                    final cops = p.reports[ReportKind.police];
                    final cover = p.reports[ReportKind.cover];
                    final line = p.reports[ReportKind.line];
                    if (shut != null) bits.add(shut.verified ? '✓ Shut down' : '⚠️ Shut down (unverified)');
                    if (cops != null) bits.add(cops.verified ? '✓ 🚨 Police' : '🚨 Police (unverified)');
                    if (cover != null) bits.add('${cover.detail ?? 'Cover'} cover${cover.verified ? '' : ' (unverified)'}');
                    if (line != null) bits.add('Line ${line.detail ?? ''}${line.verified ? '' : ' (unverified)'}');

                    final rawStory = store.latestMediaStoryFor(p.id);
                    final latestStory = isVideoStory(rawStory) && !videoRows.contains(p.id) ? null : rawStory;
                    return InkWell(
                      onTap: () => _openPlace(context, p.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: PlaceMediaThumbnail(story: latestStory, coverPhotoPath: p.coverPhotoPath, coverUrl: p.coverUrl, photoUrl: p.photoUrl, fallbackLabel: p.name.substring(0, 1), fontSize: 16),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                                      ),
                                      if (store.isPlaceVerified(p.id)) ...[
                                        const SizedBox(width: 4),
                                        // FUNKY Admin-verified gets the same
                                        // checkmark as crowd-verified, just
                                        // in the brand orange instead of
                                        // gold — a shield read as a
                                        // different kind of badge entirely
                                        // rather than a "more official"
                                        // verified checkmark. Its own tap
                                        // target (separate from the row's,
                                        // which opens the place) explains
                                        // what the badge means.
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _showVerifiedExplainer(context, isAdmin: store.isAdminVerified(p.id)),
                                          child: Icon(
                                            Icons.verified,
                                            size: 14,
                                            color: store.isAdminVerified(p.id) ? tokens.brand : tokens.gold,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    store.isPlaceVerified(p.id) ? bits.join(' · ') : '${bits.join(' · ')} · ${store.venueStatusLabel(p.id)}',
                                    style: TextStyle(color: tokens.mute, fontSize: 12.5),
                                  ),
                                ],
                              ),
                            ),
                            Text(formatMiles(p.distance), style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                          ],
                        ),
                      ),
                    );
                  }),
                const FootNote(text: 'Places are tonight-only, like everything else — wiped at 2 PM.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture inside a map pin. Tries, in order: the admin-approved picture,
/// the photo whoever added the place took, the latest photo Story there, and
/// (for a few pins only) a frame of the latest video Story — falling to the
/// next one whenever a picture fails to load, and to the place's first
/// letter only when there's truly nothing.
class _MarkerPicture extends StatelessWidget {
  final RankedPlace place;
  final Story? story;
  final bool allowVideo;
  const _MarkerPicture({required this.place, required this.story, required this.allowVideo});

  @override
  Widget build(BuildContext context) {
    final steps = <Widget Function(Widget Function() next)>[];
    Widget Function(Widget Function()) net(String url) => (next) => Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, __, ___) => next(),
        );
    Widget Function(Widget Function()) file(String path) => (next) => Image.file(
          File(path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, __, ___) => next(),
        );
    final photo = place.photoUrl;
    final coverPath = place.coverPhotoPath;
    final coverUrl = place.coverUrl;
    if (photo != null) steps.add(net(photo));
    if (coverPath != null) steps.add(file(coverPath));
    if (coverUrl != null) steps.add(net(coverUrl));
    final st = story;
    if (st?.imagePath != null) steps.add(file(st!.imagePath!));
    if (st?.imageUrl != null) steps.add(net(st!.imageUrl!));
    if (allowVideo && st != null && (st.videoPath != null || st.videoUrl != null)) {
      steps.add((next) => VideoFrameThumbnail(path: st.videoPath, url: st.videoPath == null ? st.videoUrl : null));
    }

    Widget initial() => Center(
          child: Text(
            place.name.isEmpty ? '?' : place.name.substring(0, 1),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
          ),
        );
    Widget at(int i) => i >= steps.length ? initial() : steps[i](() => at(i + 1));
    return at(0);
  }
}
