import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/mock_data.dart';
import '../data/models.dart';
import 'ui_widgets.dart';

/// Shown wherever a screen needs a location and doesn't have one yet. Real
/// location is the primary path; the town list underneath is the same
/// "testing only" escape hatch the web prototype offers so FUNKY can be
/// tried from anywhere without real foot traffic nearby.
class LocationGate extends StatelessWidget {
  const LocationGate({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    return Container(
      color: tokens.bg,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FunkyCard(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
            child: Column(
              children: [
                const Text('📍', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 10),
                Text(
                  'Your area is the 25 miles around you',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 6),
                Text(
                  "FUNKY needs your location to show you what's happening near you tonight. It's never shown to other people — only a rough area.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tokens.mute),
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: store.requestLocation,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  child: Text(
                    store.locationStatus == LocationStatus.requesting ? 'Requesting…' : 'Enable location',
                    style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800),
                  ),
                ),
                if (store.locationStatus == LocationStatus.denied) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Location was denied. You can still try FUNKY with a sample town below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: tokens.danger),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'TESTING ONLY — TRY A SAMPLE TOWN',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.mute, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: towns
                .map((town) => FunkyChip(
                      label: town.label,
                      onPressed: () => store.useTestLocation(LatLng(town.lat, town.lng)),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}
