import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../widgets/ui_widgets.dart';

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

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(place.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            height: 160,
            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(18)),
            alignment: Alignment.center,
            child: Text(place.name.substring(0, 1), style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: tokens.mute)),
          ),
          const SizedBox(height: 14),
          Text(place.name, style: TextStyle(color: tokens.ink, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${place.address} · ${formatMiles(place.distance)}', style: TextStyle(color: tokens.mute)),
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
          FunkyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reports tonight', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Shown as totals — never who reported.', style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _coverController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          hintText: 'Cover charge (\$)',
                          hintStyle: TextStyle(color: tokens.mute),
                          filled: true,
                          fillColor: tokens.raised,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                        style: TextStyle(color: tokens.ink),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: () {
                        final amt = int.tryParse(_coverController.text);
                        if (amt == null || amt < 0) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a cover amount first')));
                          return;
                        }
                        store.reportPlace(place.id, cover: amt);
                        _coverController.clear();
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => store.reportPlace(place.id, cops: !(place.cover?.cops ?? false)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: place.cover?.cops == true ? tokens.danger : tokens.raised,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text('🚨 Police', style: TextStyle(color: place.cover?.cops == true ? Colors.white : tokens.ink, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => store.reportPlace(place.id, shut: !(place.cover?.shut ?? false)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: place.cover?.shut == true ? tokens.danger : tokens.raised,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text('Shut down', style: TextStyle(color: place.cover?.shut == true ? Colors.white : tokens.ink, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

