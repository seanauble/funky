/// A photo post: a few pictures and a caption, optionally tagged at a
/// place, with likes and comments (supabase/phase29.sql). Everyone whose
/// radius reaches it can see it. Unlike a Story it doesn't expire.
class Post {
  final String id;
  final String uid; // 'me' for your own
  final String caption;
  final String? placeId;
  final String? placeName;
  // The town it was posted in, e.g. "Somers Point".
  final String? areaName;
  final double lat;
  final double lng;
  final List<String> photoPaths; // in the public 'posts' bucket
  final List<String> photoUrls;
  final int t;
  final List<String> likes; // who liked it ('me' for you)
  final List<String> dislikes; // who disliked it ('me' for you)
  final int commentCount;
  // An event (phase 31): its name, when it starts, and the cover
  // ("Free", "\$10"). Null for a normal post.
  final String? eventTitle;
  final DateTime? eventAt;
  final String? eventCover;
  final List<String> going; // who tapped "I'm going" ('me' for you)

  bool get isEvent => eventTitle != null && eventAt != null;

  /// No photos — a question/text card ("Anyone up for trivia?").
  bool get isTextOnly => photoUrls.isEmpty && !isEvent;

  /// What feeds sort by: likes minus dislikes.
  int get score => likes.length - dislikes.length;

  const Post({
    required this.id,
    required this.uid,
    required this.caption,
    required this.placeId,
    required this.placeName,
    this.areaName,
    required this.lat,
    required this.lng,
    required this.photoPaths,
    required this.photoUrls,
    required this.t,
    this.likes = const [],
    this.dislikes = const [],
    this.commentCount = 0,
    this.eventTitle,
    this.eventAt,
    this.eventCover,
    this.going = const [],
  });

  Post copyWith({List<String>? likes, List<String>? dislikes, int? commentCount, List<String>? going}) => Post(
        id: id,
        uid: uid,
        caption: caption,
        placeId: placeId,
        placeName: placeName,
        areaName: areaName,
        lat: lat,
        lng: lng,
        photoPaths: photoPaths,
        photoUrls: photoUrls,
        t: t,
        likes: likes ?? this.likes,
        dislikes: dislikes ?? this.dislikes,
        commentCount: commentCount ?? this.commentCount,
        eventTitle: eventTitle,
        eventAt: eventAt,
        eventCover: eventCover,
        going: going ?? this.going,
      );
}

/// One comment under a [Post].
class PostComment {
  final String id;
  final String postId;
  final String uid; // 'me' for your own
  final String text;
  final int t;
  /// The comment this one answers, if it's a reply.
  final String? replyTo;
  final int likes;
  final bool likedByMe;
  const PostComment({
    required this.id,
    required this.postId,
    required this.uid,
    required this.text,
    required this.t,
    this.replyTo,
    this.likes = 0,
    this.likedByMe = false,
  });

  PostComment copyWith({int? likes, bool? likedByMe}) => PostComment(
        id: id,
        postId: postId,
        uid: uid,
        text: text,
        t: t,
        replyTo: replyTo,
        likes: likes ?? this.likes,
        likedByMe: likedByMe ?? this.likedByMe,
      );
}
