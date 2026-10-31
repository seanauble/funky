import 'dart:math';
import 'models.dart';

/// Your area is the circle around you. 10 miles unless you pick your own
/// (1–50) in Settings — AppStore.setRadiusMiles keeps this in step, which is
/// why it is a plain variable rather than a constant.
const double defaultRangeMiles = 10;
const int minRangeMiles = 1;
const int maxRangeMiles = 50;
/// FUNKY Admins can look much further out — up to 5,000 miles.
const int adminMaxRangeMiles = 5000;

/// The values the radius slider snaps to: every mile from 1 to 50 for
/// everyone, plus bigger jumps out to 5,000 for admins.
List<int> radiusStops({required bool admin}) => [
      for (var m = minRangeMiles; m <= maxRangeMiles; m++) m,
      if (admin) ...const [60, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 2500, 3000, 4000, 5000],
    ];

/// Where [miles] sits on [stops] (the closest one).
int radiusStopIndex(List<int> stops, double miles) {
  var best = 0;
  for (var i = 1; i < stops.length; i++) {
    if ((stops[i] - miles).abs() < (stops[best] - miles).abs()) best = i;
  }
  return best;
}

/// "1 mile", "25 mi", "1,500 mi" — the slider label.
String radiusShortLabel(int miles) {
  if (miles == 1) return '1 mile';
  final s = miles.toString();
  final withComma = s.length > 3 ? '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}' : s;
  return '$withComma mi';
}
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
