/// A bar or club pulled in from OpenStreetMap, waiting for the admin to
/// add a photo and approve, deny, or ask for changes (supabase/phase19.sql).
class VenueCandidate {
  final String id;
  final String name;
  final String kind; // 'bar' or 'club'
  final String address;
  final double lat;
  final double lng;
  final double? distanceMiles; // from Egg Harbor
  final List<VenuePhoto> photos;
  final int photoIndex;
  // A photo the admin added (wins over any imported ones).
  final String? customPhotoUrl;
  final String status; // pending | approved | denied | changes
  final String? note;
  final String? placeId;

  const VenueCandidate({
    required this.id,
    required this.name,
    required this.kind,
    required this.address,
    required this.lat,
    required this.lng,
    required this.distanceMiles,
    required this.photos,
    required this.photoIndex,
    this.customPhotoUrl,
    required this.status,
    required this.note,
    required this.placeId,
  });

  /// The same venue with a filled-in address.
  VenueCandidate withAddress(String a) => VenueCandidate(
        id: id,
        name: name,
        kind: kind,
        address: a,
        lat: lat,
        lng: lng,
        distanceMiles: distanceMiles,
        photos: photos,
        photoIndex: photoIndex,
        customPhotoUrl: customPhotoUrl,
        status: status,
        note: note,
        placeId: placeId,
      );

  VenuePhoto? get photo => photos.isEmpty ? null : photos[photoIndex.clamp(0, photos.length - 1)];

  static VenueCandidate? fromRow(Map<String, dynamic> r) {
    final id = r['id'] as String?;
    final lat = (r['lat'] as num?)?.toDouble();
    final lng = (r['lng'] as num?)?.toDouble();
    if (id == null || lat == null || lng == null) return null;
    final rawPhotos = r['photos'];
    final photos = <VenuePhoto>[];
    if (rawPhotos is List) {
      for (final p in rawPhotos) {
        if (p is Map && p['name'] is String) photos.add(VenuePhoto(ref: p['name'] as String, credit: p['credit'] as String?));
      }
    }
    return VenueCandidate(
      id: id,
      name: (r['name'] as String?) ?? 'Unnamed',
      kind: (r['kind'] as String?) ?? 'bar',
      address: (r['address'] as String?) ?? '',
      lat: lat,
      lng: lng,
      distanceMiles: (r['distance_miles'] as num?)?.toDouble(),
      photos: photos,
      photoIndex: (r['photo_index'] as num?)?.toInt() ?? 0,
      customPhotoUrl: r['custom_photo_url'] as String?,
      status: (r['status'] as String?) ?? 'pending',
      note: r['admin_note'] as String?,
      placeId: r['place_id'] as String?,
    );
  }
}

class VenuePhoto {
  /// Google's photo name, e.g. "places/ChIJ…/photos/AUc7…".
  final String ref;
  /// Who took it (shown under the picture, as Google requires).
  final String? credit;
  const VenuePhoto({required this.ref, this.credit});
}
