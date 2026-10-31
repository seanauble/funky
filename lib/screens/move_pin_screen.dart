import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/ui_widgets.dart';

/// Admin: drag the map until the pin sits exactly on the spot, then save.
/// Returns the new position (our own LatLng), or null if cancelled.
class MovePinScreen extends StatefulWidget {
  final String title;
  final LatLng start;
  final String hint;
  final String confirmLabel;
  final double zoom;
  const MovePinScreen({
    super.key,
    required this.title,
    required this.start,
    this.hint = 'Drag the map until the pin is right on the front door.',
    this.confirmLabel = 'Save pin here',
    this.zoom = 17,
  });

  @override
  State<MovePinScreen> createState() => _MovePinScreenState();
}

class _MovePinScreenState extends State<MovePinScreen> {
  final MapController _map = MapController();
  late ll.LatLng _center = ll.LatLng(widget.start.lat, widget.start.lng);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.read<AppStore>();
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: widget.zoom,
              onPositionChanged: (camera, _) => setState(() => _center = camera.center),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.funkyapp.funky',
              ),
            ],
          ),
          // The pin stays in the middle; you move the map under it.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 44),
                child: Icon(Icons.location_on, size: 48, color: tokens.brand, shadows: const [Shadow(blurRadius: 6, color: Colors.black45)]),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(12)),
              child: Text(
                widget.hint,
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (store.location != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: FloatingActionButton.small(
                        heroTag: 'movepin_me',
                        backgroundColor: tokens.surface,
                        onPressed: () {
                          final gps = store.gpsLocation ?? store.location!;
                          _map.move(ll.LatLng(gps.lat, gps.lng), _map.camera.zoom);
                        },
                        child: Icon(Icons.my_location, color: tokens.ink),
                      ),
                    ),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pop(LatLng(_center.latitude, _center.longitude)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tokens.brand,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(widget.confirmLabel, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
