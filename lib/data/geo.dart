import 'dart:math';
import 'models.dart';

/// Your area is the 25 miles around you (rule 1) — no area picker.
const double rangeMiles = 25;

/// Great-circle distance in miles between two points.
double milesBetween(LatLng a, LatLng b) {
  const r = 3958.8;
  double toRad(double d) => d * pi / 180;
  final dLat = toRad(b.lat - a.lat);
  final dLng = toRad(b.lng - a.lng);
  final lat1 = toRad(a.lat);
  final lat2 = toRad(b.lat);
  final h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLng / 2), 2);
  return r * 2 * atan2(sqrt(h), sqrt(1 - h));
}

bool near(LatLng me, LatLng pt) => milesBetween(me, pt) <= rangeMiles;

String formatMiles(double mi) {
  if (mi < 0.1) return 'next to you';
  if (mi < 1) {
    final tenths = (mi * 10).round();
    return tenths == 10 ? '1 mi' : '${(tenths / 10).toStringAsFixed(1)} mi';
  }
  return '${mi.toStringAsFixed(1)} mi';
}
