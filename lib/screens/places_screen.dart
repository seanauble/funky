import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_heatmap_plus/flutter_map_heatmap_plus.dart' as heatmap;
import 'package:latlong2/latlong.dart' as ll;
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../widgets/location_gate.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';

const _heatLabel = ['Quiet so far', 'Some activity', 'Active', 'Very active'];

class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  // flutter_map_heatmap_plus redraws the glow layer off this stream rather
  // than on every FlutterMap rebuild, so one broadcast controller lives for
  // as long as this screen does.
  final _heatReset = StreamController<void>.broadcast();

  @override
  void dispose() {
    _heatReset.close();
    super.dispose();
  }

  void _openPlace(String placeId) {
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _heatReset.add(null);
    });

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
                    if (ranked.isNotEmpty)
                      heatmap.HeatMapLayer(
                        heatMapDataSource: heatmap.InMemoryHeatMapDataSource(
                          data: ranked
                              .map((p) => heatmap.WeightedLatLng(
                                    ll.LatLng(p.place.lat, p.place.lng),
                                    (p.score + 1).toDouble(),
                                  ))
                              .toList(),
                        ),
                        heatMapOptions: heatmap.HeatMapOptions(minOpacity: 0.35),
                        reset: _heatReset.stream,
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
                              onTap: () => _openPlace(p.id),
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
                    RichAttributionWidget(
                      attributions: [TextSourceAttribution('OpenStreetMap contributors')],
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
                    final bits = <String>[placeKindLabel(p.kind), '🔥 ${p.going} going'];
                    if (p.heat > 0) bits.add(_heatLabel[p.heat]);
                    if (p.cover?.shut == true) bits.add('Shut down');
                    if (p.cover?.cops == true) bits.add('🚨 Police');
                    if (p.cover != null && p.cover!.cover > 0) bits.add('\$${p.cover!.cover} cover');

                    return InkWell(
                      onTap: () => _openPlace(p.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.line))),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
                              alignment: Alignment.center,
                              child: p.id == topPlaceId
                                  ? const Text('👑', style: TextStyle(fontSize: 18))
                                  : Text(p.name.substring(0, 1), style: TextStyle(fontWeight: FontWeight.w800, color: tokens.mute)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 2),
                                  Text(bits.join(' · '), style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                                ],
                              ),
                            ),
                            Text(formatMiles(p.distance), style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                          ],
                        ),
                      ),
                    );
                  }),
                const FootNote(text: 'Places are tonight-only, like everything else — wiped at 4 PM.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
