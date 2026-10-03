import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (store.location == null) return const LocationGate();

    return Scaffold(
      backgroundColor: tokens.bg,
      body: Column(
        children: [
          // A real satellite map with a heat layer is next (see HANDOFF.md)
          // — this placeholder stands in for it so the screen is useful
          // today instead of blank.
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(color: tokens.map, border: Border(bottom: BorderSide(color: tokens.mapLine))),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(color: tokens.you, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                ),
                const SizedBox(height: 10),
                Text('Map view coming next — list is live below', style: TextStyle(color: tokens.mute)),
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
                    final bits = <String>[placeKindLabel(p.kind), '🔥 ${p.going} going'];
                    if (p.heat > 0) bits.add(_heatLabel[p.heat]);
                    if (p.cover?.shut == true) bits.add('Shut down');
                    if (p.cover?.cops == true) bits.add('🚨 Police');
                    if (p.cover != null && p.cover!.cover > 0) bits.add('\$${p.cover!.cover} cover');

                    return InkWell(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: p.id))),
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
                              child: Text(p.name.substring(0, 1), style: TextStyle(fontWeight: FontWeight.w800, color: tokens.mute)),
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
