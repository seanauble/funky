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
    final topPlaceId = ranked.isNotEmpty ? ranked.first.id : null;
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
                  options: MapOptions(
                    initialCenter: ll.LatLng(here.lat, here.lng),
                    initialZoom: 12,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.funkyapp.funky',
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
                          final glowColor = p.id == topPlaceId ? tokens.brand : tokens.orange;
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
                          final isTop = p.id == topPlaceId;
                          final size = isTop ? 40.0 : 28.0;
                          return Marker(
                            point: ll.LatLng(p.place.lat, p.place.lng),
                            width: size,
                            height: size,
                            child: GestureDetector(
                              onTap: () => _openPlace(context, p.id),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isTop ? tokens.brand : tokens.orange,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: isTop ? 3 : 2),
                                  boxShadow: isTop
                                      ? [BoxShadow(color: tokens.brand.withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 2)]
                                      : null,
                                ),
                                alignment: Alignment.center,
                                child: isTop
                                    ? const Text('👑', style: TextStyle(fontSize: 16))
                                    : Text(
                                        p.name.substring(0, 1),
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                                      ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                    // Plain, non-interactive text credit — no flutter_map
                    // logo button, no tappable "i" info icon, just the
                    // small attribution line OpenStreetMap's tile usage
                    // policy requires somewhere on the map.
                    const SimpleAttributionWidget(
                      source: Text('© OpenStreetMap contributors'),
                    ),
                  ],
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '👑 marks tonight\'s busiest spot — the glow shows where votes and Stories are piling up.',
              style: TextStyle(color: tokens.mute, fontSize: 12),
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

                    final latestStory = store.latestMediaStoryFor(p.id);
                    return InkWell(
                      onTap: () => _openPlace(context, p.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
                        child: Row(
                          children: [
                            // 👑 for tonight's busiest spot always wins over
                            // the media preview — that crown is the more
                            // useful signal in a one-line list row.
                            if (p.id == topPlaceId)
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
                                alignment: Alignment.center,
                                child: const Text('👑', style: TextStyle(fontSize: 18)),
                              )
                            else
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: PlaceMediaThumbnail(story: latestStory, fallbackLabel: p.name.substring(0, 1), fontSize: 16),
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
                                        // verified checkmark.
                                        Icon(
                                          Icons.verified,
                                          size: 14,
                                          color: store.isAdminVerified(p.id) ? tokens.brand : tokens.gold,
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
