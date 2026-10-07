import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import 'ui_widgets.dart';

/// Shown wherever a screen needs a location and doesn't have one yet. Real
/// location only now — the "testing only, try a sample town" escape hatch
/// the web prototype offered (and this screen used to carry over) is gone,
/// so FUNKY only ever shows you what's actually near wherever you really
/// are. AppStore.load() already fires requestLocation() automatically on
/// every launch, so in practice most people never even see this screen —
/// it's just the fallback for the one time location genuinely needs an OS
/// prompt (first install) or was denied.
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
                  'Your area is the ${rangeLabel()} around you',
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
                    "Location was denied. Turn it on for FUNKY in your phone's Settings, then tap Enable location again.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: tokens.danger),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
