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

/// Someone flagged a Story; admins review these (supabase/phase26.sql).
/// Carries a copy of the Story so it can still be judged after it expires
/// or is deleted — and the real poster even when it was posted anonymously.
/// Several reports on the same Story are grouped into one of these.
class StoryReport {
  final String id; // the oldest open report on this Story
  final List<String> reportIds;
  final String? storyId;
  // 'story', or 'post' for a reported photo post (phase 29) — then postId
  // is set and storyMediaPath is the first photo in the public posts bucket.
  final String kind;
  final String? postId;
  final String? posterId; // 'me' for your own
  final List<String> reasons;
  final List<String> reporterIds; // 'me' for your own
  final String? storyText;
  final String? storyMediaPath;
  final bool storyIsVideo;
  final bool storyAnon;
  final String? storyPlaceName;
  final DateTime? storyCreatedAt;
  final DateTime createdAt;
  const StoryReport({
    required this.id,
    required this.reportIds,
    required this.storyId,
    this.kind = 'story',
    this.postId,
    required this.posterId,
    required this.reasons,
    required this.reporterIds,
    required this.storyText,
    required this.storyMediaPath,
    required this.storyIsVideo,
    required this.storyAnon,
    required this.storyPlaceName,
    required this.storyCreatedAt,
    required this.createdAt,
  });

  bool get isPost => kind == 'post';
}

/// One error report sent from someone's phone (supabase/phase32.sql).
class CrashReport {
  final String id;
  final String message;
  final String? stack;
  final String? context;
  final bool fatal;
  final String? build;
  final String? platform;
  final String? userId;
  final DateTime at;
  const CrashReport({
    required this.id,
    required this.message,
    required this.stack,
    required this.context,
    required this.fatal,
    required this.build,
    required this.platform,
    required this.userId,
    required this.at,
  });
}
