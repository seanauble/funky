import 'dart:math';
import 'models.dart';

/// Your area is the circle around you. 10 miles unless you pick your own
/// (1–50) in Settings — AppStore.setRadiusMiles keeps this in step, which is
/// why it is a plain variable rather than a constant.
const double defaultRangeMiles = 10;
const int minRangeMiles = 1;
const int maxRangeMiles = 50;
double rangeMiles = defaultRangeMiles;

/// "25 miles" / "1 mile" — for the sentences that name your area.
String rangeLabel() {
  final n = rangeMiles.round();
  return n == 1 ? '1 mile' : '$n miles';
}

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

/// A deliberately rough "how far away" for Live Chat — an upper bound
/// ("<5 mi away"), never an exact distance, so it can't be used to pin
/// someone down.
String awayLabel(double miles) {
  const steps = [1, 2, 3, 5, 10, 15, 20, 30, 40, 50, 75, 100];
  for (final s in steps) {
    if (miles < s) return '<$s mi away';
  }
  return '100+ mi away';
}

String formatMiles(double mi) {
  if (mi < 0.1) return 'next to you';
  if (mi < 1) {
    final tenths = (mi * 10).round();
    return tenths == 10 ? '1 mi' : '${(tenths / 10).toStringAsFixed(1)} mi';
  }
  return '${mi.toStringAsFixed(1)} mi';
}
