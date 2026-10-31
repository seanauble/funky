import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Downloads every bar, pub, beer garden and nightclub within [radiusMiles]
/// of a spot from OpenStreetMap (free, no key) — straight from the phone,
/// since the shared servers Supabase functions run on get turned away as
/// "busy". Map data © OpenStreetMap contributors.
class OsmVenueFetcher {
  static const _servers = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  /// Rows ready for the import_venue_candidates database function, or
  /// throws with a readable message.
  static Future<List<Map<String, dynamic>>> fetch({required double lat, required double lng, double radiusMiles = 50}) async {
    final meters = (radiusMiles * 1609.344).round();
    final query = '[out:json][timeout:90];\n'
        '(nwr["amenity"~"^(bar|pub|nightclub|biergarten)\$"](around:$meters,$lat,$lng););\n'
        'out center tags;';
    final errors = <String>[];
    for (final server in _servers) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final elements = await _ask(server, query);
          return _rows(elements, lat, lng, radiusMiles);
        } on _Busy catch (e) {
          errors.add(e.message);
          // Give a busy server a moment, then try once more before moving on.
          if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 3));
        } catch (e) {
          errors.add('${Uri.parse(server).host}: $e');
          break;
        }
      }
    }
    throw Exception('Couldn\'t reach OpenStreetMap right now (${errors.isEmpty ? 'no answer' : errors.last}). Try again in a minute.');
  }

  static Future<List<dynamic>> _ask(String server, String query) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(Uri.parse(server));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
      req.headers.set(HttpHeaders.userAgentHeader, 'FUNKY-app/1.0 (nightlife app; venue import)');
      req.write('data=${Uri.encodeQueryComponent(query)}');
      final res = await req.close().timeout(const Duration(seconds: 100));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 429 || res.statusCode == 504 || res.statusCode == 503) {
        throw _Busy('${Uri.parse(server).host} is busy (${res.statusCode})');
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(body);
      if (data is! Map || data['elements'] is! List) throw Exception('unexpected answer');
      return data['elements'] as List<dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static double _miles(double aLat, double aLng, double bLat, double bLng) {
    const r = 3958.8;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(bLat - aLat);
    final dLng = rad(bLng - aLng);
    final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(aLat)) * math.cos(rad(bLat)) * math.pow(math.sin(dLng / 2), 2);
    return r * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  static String _address(Map<String, dynamic> t) {
    final full = t['addr:full'];
    if (full is String && full.isNotEmpty) return full;
    final street = [t['addr:housenumber'], t['addr:street']].whereType<String>().join(' ');
    final city = (t['addr:city'] ?? t['addr:town'] ?? t['addr:village'] ?? '') as String;
    final stateZip = [t['addr:state'], t['addr:postcode']].whereType<String>().join(' ');
    return [street, city, stateZip].where((s) => s.trim().isNotEmpty).join(', ');
  }

  static List<Map<String, dynamic>> _rows(List<dynamic> elements, double lat, double lng, double radiusMiles) {
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final raw in elements) {
      if (raw is! Map) continue;
      final el = raw.cast<String, dynamic>();
      final tags = (el['tags'] is Map) ? (el['tags'] as Map).cast<String, dynamic>() : <String, dynamic>{};
      final name = (tags['name'] as String? ?? '').trim();
      final center = el['center'] is Map ? (el['center'] as Map).cast<String, dynamic>() : null;
      final vLat = ((el['lat'] ?? center?['lat']) as num?)?.toDouble();
      final vLng = ((el['lon'] ?? center?['lon']) as num?)?.toDouble();
      if (name.isEmpty || vLat == null || vLng == null) continue;
      if (tags['disused:amenity'] != null || tags['opening_hours'] == 'closed') continue;
      // The same spot mapped twice (a pin and a building outline).
      final key = '${name.toLowerCase()}@${vLat.toStringAsFixed(3)},${vLng.toStringAsFixed(3)}';
      if (!seen.add(key)) continue;
      final miles = _miles(lat, lng, vLat, vLng);
      if (miles > radiusMiles) continue;
      rows.add({
        'source_id': 'osm:${el['type']}/${el['id']}',
        'name': name.length > 60 ? name.substring(0, 60) : name,
        'kind': tags['amenity'] == 'nightclub' ? 'club' : 'bar',
        'address': _address(tags),
        'lat': vLat,
        'lng': vLng,
        'distance_miles': (miles * 10).round() / 10,
      });
    }
    return rows;
  }
}

class _Busy implements Exception {
  final String message;
  _Busy(this.message);
}
