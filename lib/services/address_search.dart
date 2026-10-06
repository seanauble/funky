import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One address / venue suggestion from [AddressSearch].
class AddressResult {
  /// Short headline — the venue name, or the street line for a plain address.
  final String title;

  /// The full address line, e.g. "123 Main St, Philadelphia, PA 19103".
  final String address;
  final double lat;
  final double lng;

  /// True when this is a named venue (a bar, a club…) rather than a bare address.
  final bool isVenue;

  const AddressResult({required this.title, required this.address, required this.lat, required this.lng, required this.isVenue});

  /// What to show under the headline in the suggestion list.
  String get subtitle => isVenue ? address : '';
}

/// Address / venue lookup for the Add Place form, using the free Photon
/// geocoder (built on OpenStreetMap data) — no API key and no extra package.
/// Any failure just returns an empty list so the form keeps working.
class AddressSearch {
  static String? _clean(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  static Future<List<AddressResult>> search(String query, {double? nearLat, double? nearLng}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final params = <String, String>{
      'q': q,
      'limit': '8',
      if (nearLat != null && nearLng != null) 'lat': nearLat.toStringAsFixed(5),
      if (nearLat != null && nearLng != null) 'lon': nearLng.toStringAsFixed(5),
    };
    final uri = Uri.https('photon.komoot.io', '/api/', params);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      req.headers.set(HttpHeaders.userAgentHeader, 'FUNKY-app/3.0 (nightlife social app)');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final features = decoded['features'];
      if (features is! List) return const [];
      final out = <AddressResult>[];
      final seen = <String>{};
      for (final f in features) {
        if (f is! Map) continue;
        final geometry = f['geometry'];
        final props = f['properties'];
        if (geometry is! Map || props is! Map) continue;
        final coords = geometry['coordinates'];
        if (coords is! List || coords.length < 2) continue;
        final lng = (coords[0] as num?)?.toDouble();
        final lat = (coords[1] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        final name = _clean(props['name']);
        final house = _clean(props['housenumber']);
        final street = _clean(props['street']);
        final streetLine = street == null ? null : (house == null ? street : '$house $street');
        final city = _clean(props['city']) ?? _clean(props['locality']) ?? _clean(props['district']) ?? _clean(props['county']);
        final state = _clean(props['state']);
        final zip = _clean(props['postcode']);
        final statePart = [state, zip].whereType<String>().join(' ');

        // A named venue (bar, club, restaurant…) as opposed to a bare street
        // address or a whole city/state.
        final kind = _clean(props['type']);
        final osmKey = _clean(props['osm_key']);
        const areaKinds = {'city', 'state', 'country', 'county', 'district', 'locality', 'street', 'postcode'};
        const nonVenueKeys = {'place', 'boundary', 'highway'};
        final String? venueName =
            (name != null && name != streetLine && !areaKinds.contains(kind) && !nonVenueKeys.contains(osmKey)) ? name : null;
        final isVenue = venueName != null;
        final addressParts = <String>[
          if (streetLine != null) streetLine else if (name != null && !isVenue) name,
          if (city != null && city != name) city,
          if (statePart.isNotEmpty) statePart,
        ];
        if (addressParts.isEmpty) continue;
        final address = addressParts.join(', ');
        final title = venueName ?? address;
        final key = '${title.toLowerCase()}|${address.toLowerCase()}';
        if (!seen.add(key)) continue;
        out.add(AddressResult(title: title, address: address, lat: lat, lng: lng, isVenue: isVenue));
      }
      return out;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}
