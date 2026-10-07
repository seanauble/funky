/// A picture someone suggested for a place, waiting for a FUNKY Admin to
/// approve it (see supabase/phase10.sql).
class PlacePhotoSuggestion {
  final String id;
  final String placeId;
  final String userId; // 'me' for your own
  final String url;
  const PlacePhotoSuggestion({required this.id, required this.placeId, required this.userId, required this.url});
}

/// Someone reported a profile; the admin reviews these (supabase/phase10.sql).
class ProfileReport {
  final String id;
  final String reporterId; // 'me' for your own
  final String reportedId;
  final String reason;
  final DateTime createdAt;
  const ProfileReport({
    required this.id,
    required this.reporterId,
    required this.reportedId,
    required this.reason,
    required this.createdAt,
  });
}
