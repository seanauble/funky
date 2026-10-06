/// Mirrors the data model documented in HANDOFF.md ("Data model (as stored
/// inside Claude)") so swapping the mock store for a real backend later is
/// a matter of changing where these records come from, not what shape they
/// are.
library;

import 'session.dart';

class LatLng {
  final double lat;
  final double lng;
  const LatLng(this.lat, this.lng);
}

enum PlaceKind { frat, party, bar, club, event, tailgate, area }

String placeKindLabel(PlaceKind kind) {
  switch (kind) {
    case PlaceKind.frat:
      return 'Fraternity';
    case PlaceKind.party:
      return 'Party';
    case PlaceKind.bar:
      return 'Bar';
    case PlaceKind.club:
      return 'Club';
    case PlaceKind.event:
      return 'Event';
    case PlaceKind.tailgate:
      return 'Tailgate';
    case PlaceKind.area:
      return 'Area';
  }
}

/// 8 unique confirmations flips a report from UNVERIFIED to VERIFIED — the
/// person who posted it counts as the first confirmation.
const int verificationThreshold = 8;

enum ReportKind { cover, police, shutdown, line, capacity }

String reportKindLabel(ReportKind kind) {
  switch (kind) {
    case ReportKind.cover:
      return 'Cover charge';
    case ReportKind.police:
      return 'Police';
    case ReportKind.shutdown:
      return 'Shut down';
    case ReportKind.line:
      return 'Line / wait';
    case ReportKind.capacity:
      return 'At capacity';
  }
}

/// A single crowd-sourced report about a place tonight — a cover charge, a
/// police sighting, a shutdown, a line, or a capacity warning. Replaces the
/// old one-Report-per-place model: this one tracks WHO has confirmed it (so
/// the UI can show a real "confirmed by N people" count and flip to
/// VERIFIED once 8 unique people back it up) instead of just overwriting
/// one person's say-so. A new report for the same place+kind supersedes the
/// old one and starts its own confirmation count from scratch — see
/// AppStore.reportsFor, which only ever surfaces the newest one per kind.
class PlaceReport {
  final String id;
  final String placeId;
  final ReportKind kind;
  // "$15" for cover, "20 min" for a line — null for police/shutdown/capacity,
  // which are just "this is happening right now" taps with no extra detail.
  final String? detail;
  final int t;
  final String reporterId;
  final List<String> confirmedBy;

  const PlaceReport({
    required this.id,
    required this.placeId,
    required this.kind,
    this.detail,
    required this.t,
    required this.reporterId,
    required this.confirmedBy,
  });

  int get confirmations => confirmedBy.length;
  bool get verified => confirmations >= verificationThreshold;

  PlaceReport copyWith({List<String>? confirmedBy}) => PlaceReport(
        id: id,
        placeId: placeId,
        kind: kind,
        detail: detail,
        t: t,
        reporterId: reporterId,
        confirmedBy: confirmedBy ?? this.confirmedBy,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'placeId': placeId,
        'kind': kind.name,
        'detail': detail,
        't': t,
        'reporterId': reporterId,
        'confirmedBy': confirmedBy,
      };

  factory PlaceReport.fromJson(Map<String, dynamic> json) => PlaceReport(
        id: json['id'] as String,
        placeId: json['placeId'] as String,
        kind: ReportKind.values.firstWhere((k) => k.name == json['kind'], orElse: () => ReportKind.cover),
        detail: json['detail'] as String?,
        t: json['t'] as int,
        reporterId: json['reporterId'] as String,
        confirmedBy: (json['confirmedBy'] as List).map((e) => e as String).toList(),
      );
}

class Place {
  final String id;
  final String name;
  final PlaceKind kind;
  final double lat;
  final double lng;
  final String address;
  final String by;
  final int t;
  final String session;
  // Optional photo the person who added this place snapped with FUNKY's own
  // camera (see _PlaceFormPage) — shown as the place's thumbnail/banner
  // until somebody posts an actual Story there, at which point
  // PlaceMediaThumbnail prefers that Story's media instead. Null for a
  // place added without one (the plain colored-letter box is the fallback
  // under that).
  final String? coverPhotoPath;
  // The same photo as a public URL on the backend — what everyone ELSE sees
  // (coverPhotoPath is only a file on the device that added the place).
  final String? coverUrl;

  const Place({
    required this.id,
    required this.name,
    required this.kind,
    required this.lat,
    required this.lng,
    required this.address,
    required this.by,
    required this.t,
    required this.session,
    this.coverPhotoPath,
    this.coverUrl,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'lat': lat,
        'lng': lng,
        'address': address,
        'by': by,
        't': t,
        'session': session,
        'coverPhotoPath': coverPhotoPath,
        'coverUrl': coverUrl,
      };

  factory Place.fromJson(Map<String, dynamic> json) => Place(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: PlaceKind.values.firstWhere((k) => k.name == json['kind'], orElse: () => PlaceKind.area),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        address: json['address'] as String,
        by: json['by'] as String,
        t: json['t'] as int,
        session: json['session'] as String,
        coverPhotoPath: json['coverPhotoPath'] as String?,
        coverUrl: json['coverUrl'] as String?,
      );
}

class Poll {
  final String id;
  final String q;
  final List<String> options;
  final double lat;
  final double lng;
  final String by;
  final int t;
  final String session;

  const Poll({
    required this.id,
    required this.q,
    required this.options,
    required this.lat,
    required this.lng,
    required this.by,
    required this.t,
    required this.session,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'q': q,
        'options': options,
        'lat': lat,
        'lng': lng,
        'by': by,
        't': t,
        'session': session,
      };

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
        id: json['id'] as String,
        q: json['q'] as String,
        options: (json['options'] as List).map((e) => e as String).toList(),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        by: json['by'] as String,
        t: json['t'] as int,
        session: json['session'] as String,
      );
}

class ChatMessage {
  final String id;
  final int t;
  final String room; // "main" (area chat) or a DM room (see dmRoomId)
  final String uid;
  final String text;
  final bool anon;
  // Emoji -> ids of everyone who reacted with it (double-tap for a quick ❤️,
  // or hold a message for the full picker). Same ids-not-shown-by-name
  // shape as Story views/likes — the sender only ever sees counts, never
  // who reacted, except for their own reaction reflecting back as active.
  final Map<String, List<String>> reactions;
  // Delivery state of a message YOU sent: 'sending' (still on its way),
  // 'sent'/'delivered' (the server has it), 'seen' (they opened the
  // thread), or 'failed'. Everything received from someone else is just
  // 'delivered'.
  final String status;
  // A photo or video attached to a DM ('image' or 'video'), or null for a
  // plain text message. mediaPath is a file on THIS device (what you just
  // sent); mediaUrl is a temporary signed download URL for the other
  // person's media — never persisted, always re-resolved fresh.
  final String? mediaType;
  final String? mediaPath;
  final String? mediaUrl;
  // Where the sender was when they sent a Live Chat message — what lets
  // "everyone within 25 miles" actually mean that. Null for DMs.
  final double? lat;
  final double? lng;

  const ChatMessage({
    required this.id,
    required this.t,
    required this.room,
    required this.uid,
    required this.text,
    required this.anon,
    this.reactions = const {},
    this.status = 'delivered',
    this.mediaType,
    this.mediaPath,
    this.mediaUrl,
    this.lat,
    this.lng,
  });

  bool get hasMedia => mediaType != null && (mediaPath != null || mediaUrl != null);

  ChatMessage copyWith({
    String? id,
    Map<String, List<String>>? reactions,
    String? status,
    String? mediaUrl,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        t: t,
        room: room,
        uid: uid,
        text: text,
        anon: anon,
        reactions: reactions ?? this.reactions,
        status: status ?? this.status,
        mediaType: mediaType,
        mediaPath: mediaPath,
        mediaUrl: mediaUrl ?? this.mediaUrl,
        lat: lat,
        lng: lng,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        't': t,
        'room': room,
        'uid': uid,
        'text': text,
        'anon': anon,
        'reactions': reactions.map((emoji, uids) => MapEntry(emoji, uids)),
        'status': status,
        'mediaType': mediaType,
        'mediaPath': mediaPath,
        'lat': lat,
        'lng': lng,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        t: json['t'] as int,
        room: json['room'] as String,
        uid: json['uid'] as String,
        text: json['text'] as String,
        anon: json['anon'] as bool,
        reactions: ((json['reactions'] as Map?) ?? const {}).map(
          (emoji, uids) => MapEntry(emoji as String, (uids as List).map((e) => e as String).toList()),
        ),
        status: json['status'] as String? ?? 'delivered',
        mediaType: json['mediaType'] as String?,
        mediaPath: json['mediaPath'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
      );
}

class Story {
  final String id;
  final int t;
  final String uid;
  final String? text;
  final String? place; // "main" or a place id — which ring it belongs to
  final bool anon;
  final String session;
  final List<String> views;
  final List<String> likes;
  // Who screenshotted this Story — same idea as views/likes (ids, not shown
  // to the poster by name). The poster only ever sees a count.
  final List<String> screenshotBy;
  // Local file path to the captured photo, once camera Stories are posted
  // with one. Null for a text-only Story. This is a path on THIS device —
  // there's no backend yet, so a photo Story only ever plays back on the
  // device that posted it (same limitation every "other people's" count in
  // this mock store has).
  final String? imagePath;
  // Local file path to a captured video (max 15s), mutually exclusive with
  // imagePath in practice (a Story is either a photo or a video, never
  // both) but kept as a separate nullable field rather than a tagged union
  // to match the rest of this mock model. Same single-device limitation as
  // imagePath above.
  final String? videoPath;
  // A snapshot of the place's name at the moment this Story was posted.
  // Places themselves are tonight-only (wiped at 2 PM, rule 2) but a
  // Story's entry in Memories is permanent, so by the time you look back
  // at an old Memory the place record it pointed to may be long gone —
  // this is what lets Memories still say "Posted at Sigma Chi" anyway.
  // Null for a general/"main" Story.
  final String? placeName;
  // Your own Memories auto-delete memoryRetentionDays after posting unless
  // this is true — "Save to Timeline" (the bookmark action on a Memory, or
  // the swipe-up sheet on your own Story) sets it, and that's the only way
  // to keep one around forever. Always false for anyone but 'me' in
  // practice, since only your own Stories are ever kept as Memories at all.
  final bool savedToTimeline;
  // A resolved, temporary download URL for someone else's photo/video,
  // fetched live from Supabase Storage (see AppStore's real-backend sync
  // section) — set only for a Story that came from the real backend and
  // isn't already playable from a local file on this device (your own
  // Stories always have that local imagePath/videoPath instead, from when
  // you captured them, and keep using that). Null for anything local-only
  // or text-only. Deliberately left out of toJson/fromJson — a signed URL
  // expires, so it's always worth re-resolving fresh rather than caching.
  final String? imageUrl;
  final String? videoUrl;

  const Story({
    required this.id,
    required this.t,
    required this.uid,
    this.text,
    this.place,
    required this.anon,
    required this.session,
    required this.views,
    required this.likes,
    this.screenshotBy = const [],
    this.imagePath,
    this.videoPath,
    this.placeName,
    this.savedToTimeline = false,
    this.imageUrl,
    this.videoUrl,
  });

  Story copyWith({List<String>? likes, List<String>? views, List<String>? screenshotBy, bool? savedToTimeline}) => Story(
        id: id,
        t: t,
        uid: uid,
        text: text,
        place: place,
        anon: anon,
        session: session,
        views: views ?? this.views,
        likes: likes ?? this.likes,
        screenshotBy: screenshotBy ?? this.screenshotBy,
        imagePath: imagePath,
        videoPath: videoPath,
        placeName: placeName,
        savedToTimeline: savedToTimeline ?? this.savedToTimeline,
        imageUrl: imageUrl,
        videoUrl: videoUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        't': t,
        'uid': uid,
        'text': text,
        'place': place,
        'anon': anon,
        'session': session,
        'views': views,
        'likes': likes,
        'screenshotBy': screenshotBy,
        'imagePath': imagePath,
        'videoPath': videoPath,
        'placeName': placeName,
        'savedToTimeline': savedToTimeline,
      };

  factory Story.fromJson(Map<String, dynamic> json) => Story(
        id: json['id'] as String,
        t: json['t'] as int,
        uid: json['uid'] as String,
        text: json['text'] as String?,
        place: json['place'] as String?,
        anon: json['anon'] as bool,
        session: json['session'] as String,
        views: (json['views'] as List).map((e) => e as String).toList(),
        likes: (json['likes'] as List).map((e) => e as String).toList(),
        screenshotBy: ((json['screenshotBy'] as List?) ?? const []).map((e) => e as String).toList(),
        imagePath: json['imagePath'] as String?,
        videoPath: json['videoPath'] as String?,
        placeName: json['placeName'] as String?,
        savedToTimeline: json['savedToTimeline'] as bool? ?? false,
      );
}

// Memories auto-delete this many days after posting unless explicitly
// saved to your Timeline (Story.savedToTimeline) — see
// AppStore._purgeExpiredMemories and the save/removeFromTimeline actions.
const memoryRetentionDays = 7;

/// Days left before [story] auto-deletes, clamped to 0 ("expiring today").
/// Meaningless (and never shown) once savedToTimeline is true.
/// How long ago something was posted, for the Story header: "just now",
/// "26m ago", then whole hours — "1hr ago", "2hr ago" (never "75m ago") —
/// and, past a full day, "1d ago".
String timeAgoLabel(int timestampMs) {
  final diff = DateTime.now().millisecondsSinceEpoch - timestampMs;
  final minutes = diff <= 0 ? 0 : diff ~/ 60000;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '${minutes}m ago';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}hr ago';
  return '${hours ~/ 24}d ago';
}

int memoryDaysLeft(Story story) {
  final elapsedMs = DateTime.now().millisecondsSinceEpoch - story.t;
  final elapsedDays = (elapsedMs / (1000 * 60 * 60 * 24)).floor();
  final left = memoryRetentionDays - elapsedDays;
  return left < 0 ? 0 : left;
}

class Person {
  final String id;
  final String handle;
  final String bio;
  final int since;
  final int points;
  // Mutual friends — both people have to accept before either shows up here.
  // Friends can see each other's old Story posts on their profile; nobody
  // else can. Survives the 2 PM reset, same as DMs (rule 3).
  final List<String> friends;
  final List<String> friendRequestsSent; // ids I've asked, awaiting their accept
  final List<String> friendRequestsReceived; // ids who've asked me, awaiting my accept
  final List<String> muted;
  final bool anon;
  final bool demo;

  // Tonight only — cleared by the 2 PM reset per rule 2.
  final String session;
  final String? move; // a place id, "in" (staying in), or null (hasn't picked)
  final Map<String, int> votes; // pollId -> option index
  final List<String> seen;
  final List<String> likes;

  // --- FUNKY Points history — cumulative, survives the 2 PM reset same as
  // friends/DMs (none of this is "tonight only"). See AppStore's points
  // comment for exactly what earns what; these three fields are just the
  // history those rules read and write.
  //
  // Every session key (YYYY-MM-DD) the person did at least one
  // points-earning thing — powers the Night Owl badge and the activity
  // streak bonus (see AppStore._recordNightActivity).
  final List<String> activeNights;
  // Current consecutive-night streak, recomputed alongside activeNights.
  final int streak;
  // Every distinct place id the person has ever marked themselves "going"
  // to — powers the Explorer badge.
  final List<String> placesVisited;

  // Local file path to a profile photo taken with the in-app camera (same
  // "no gallery/image-picker" rule as Stories — see CameraCaptureScreen).
  // Null falls back to the colored-initial avatar. Cumulative, survives
  // the 2 PM reset.
  final String? photoPath;
  // Epoch ms of the last time the handle actually changed — null if it
  // never has. Drives the 15-day change cooldown in AppStore.setHandle.
  final int? lastHandleChangeAt;

  // Which points-level title to actually show beside your name — you keep
  // every title you've ever reached (see levelTitles) and get to pick
  // which one to display instead of it always being the highest, e.g.
  // someone past KING FUNKY can still choose to show off 'Party Animal'.
  // Null means "just show the highest one I've reached" (the old default).
  final int? displayedTitleThreshold;

  // Cosmetic name styling unlocked by points, same spirit as the level
  // titles — each one togglable independently once unlocked (500 bold,
  // 1000 italic, 2000 underline, 5000 a checkmark badge after your name),
  // and every unlocked style you've turned on applies at once. See
  // canUseBoldName/canUseItalicName/canUseUnderlineName/canUseCheckName
  // below for the thresholds and AppStore.setNameStyle for how these flip.
  final bool nameBold;
  final bool nameItalic;
  final bool nameUnderline;
  final bool nameCheckbox;
  // A custom name color (ARGB int, same as Color.value) picked with the
  // color selector in Customize your name — unlocked by points like every
  // other name style (see canUseNameColor). Null means "no custom color",
  // i.e. whatever default color that surface already uses.
  final int? nameColor;

  // The "going" streak: how many days in a row this person has voted for a
  // place they're going to (see AppStore.setMove). moveStreakDay is the
  // session key (YYYY-MM-DD, same format as sessionKey()) of the last day
  // that counted — use effectiveMoveStreak() rather than reading
  // moveStreak directly, since a missed day silently kills the streak
  // without anything ever having to rewrite this field.
  final int moveStreak;
  final String? moveStreakDay;

  // A remote profile photo (a public URL from Supabase Storage) for real
  // accounts other than your own — photoPath above is only ever a file on
  // THIS device. FunkyAvatar prefers photoPath, then this, then the initial.
  final String? photoUrl;

  // True for the one real FUNKY Admin account as seen by everyone else
  // (profiles.is_admin on the backend) — what lets the gold admin badge
  // show on their name on EVERY device, not just their own. Your own
  // record uses AppStore.isAdmin instead. Never persisted.
  final bool isAdminUser;

  const Person({
    required this.id,
    required this.handle,
    required this.bio,
    required this.since,
    required this.points,
    required this.friends,
    required this.friendRequestsSent,
    required this.friendRequestsReceived,
    required this.muted,
    required this.anon,
    this.demo = false,
    required this.session,
    this.move,
    required this.votes,
    required this.seen,
    required this.likes,
    this.activeNights = const [],
    this.streak = 0,
    this.placesVisited = const [],
    this.photoPath,
    this.lastHandleChangeAt,
    this.displayedTitleThreshold,
    this.nameBold = false,
    this.nameItalic = false,
    this.nameUnderline = false,
    this.nameCheckbox = false,
    this.nameColor,
    this.moveStreak = 0,
    this.moveStreakDay,
    this.photoUrl,
    this.isAdminUser = false,
  });

  Person copyWith({
    bool? isAdminUser,
    String? handle,
    String? bio,
    String? move,
    Map<String, int>? votes,
    String? session,
    List<String>? friends,
    List<String>? friendRequestsSent,
    List<String>? friendRequestsReceived,
    bool? anon,
    int? points,
    List<String>? activeNights,
    int? streak,
    List<String>? placesVisited,
    String? photoPath,
    int? lastHandleChangeAt,
    bool clearLastHandleChange = false,
    int? displayedTitleThreshold,
    bool clearDisplayedTitleThreshold = false,
    bool? nameBold,
    bool? nameItalic,
    bool? nameUnderline,
    bool? nameCheckbox,
    int? nameColor,
    bool clearNameColor = false,
    int? moveStreak,
    String? moveStreakDay,
    String? photoUrl,
    bool clearMove = false,
    List<String>? seen,
    List<String>? likes,
    List<String>? muted,
  }) =>
      Person(
        id: id,
        handle: handle ?? this.handle,
        bio: bio ?? this.bio,
        since: since,
        points: points ?? this.points,
        friends: friends ?? this.friends,
        friendRequestsSent: friendRequestsSent ?? this.friendRequestsSent,
        friendRequestsReceived: friendRequestsReceived ?? this.friendRequestsReceived,
        muted: muted ?? this.muted,
        anon: anon ?? this.anon,
        demo: demo,
        session: session ?? this.session,
        move: clearMove ? null : (move ?? this.move),
        votes: votes ?? this.votes,
        seen: seen ?? this.seen,
        likes: likes ?? this.likes,
        activeNights: activeNights ?? this.activeNights,
        streak: streak ?? this.streak,
        placesVisited: placesVisited ?? this.placesVisited,
        photoPath: photoPath ?? this.photoPath,
        lastHandleChangeAt: clearLastHandleChange ? null : (lastHandleChangeAt ?? this.lastHandleChangeAt),
        displayedTitleThreshold: clearDisplayedTitleThreshold ? null : (displayedTitleThreshold ?? this.displayedTitleThreshold),
        nameBold: nameBold ?? this.nameBold,
        nameItalic: nameItalic ?? this.nameItalic,
        nameUnderline: nameUnderline ?? this.nameUnderline,
        nameCheckbox: nameCheckbox ?? this.nameCheckbox,
        nameColor: clearNameColor ? null : (nameColor ?? this.nameColor),
        moveStreak: moveStreak ?? this.moveStreak,
        moveStreakDay: moveStreakDay ?? this.moveStreakDay,
        photoUrl: photoUrl ?? this.photoUrl,
        isAdminUser: isAdminUser ?? this.isAdminUser,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'handle': handle,
        'bio': bio,
        'since': since,
        'points': points,
        'friends': friends,
        'friendRequestsSent': friendRequestsSent,
        'friendRequestsReceived': friendRequestsReceived,
        'muted': muted,
        'anon': anon,
        'demo': demo,
        'session': session,
        'move': move,
        'votes': votes,
        'seen': seen,
        'likes': likes,
        'activeNights': activeNights,
        'streak': streak,
        'placesVisited': placesVisited,
        'photoPath': photoPath,
        'lastHandleChangeAt': lastHandleChangeAt,
        'displayedTitleThreshold': displayedTitleThreshold,
        'nameBold': nameBold,
        'nameItalic': nameItalic,
        'nameUnderline': nameUnderline,
        'nameCheckbox': nameCheckbox,
        'nameColor': nameColor,
        'moveStreak': moveStreak,
        'moveStreakDay': moveStreakDay,
        'photoUrl': photoUrl,
      };

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        id: json['id'] as String,
        handle: json['handle'] as String,
        bio: json['bio'] as String,
        since: json['since'] as int,
        points: json['points'] as int,
        friends: ((json['friends'] as List?) ?? const []).map((e) => e as String).toList(),
        friendRequestsSent: ((json['friendRequestsSent'] as List?) ?? const []).map((e) => e as String).toList(),
        friendRequestsReceived: ((json['friendRequestsReceived'] as List?) ?? const []).map((e) => e as String).toList(),
        muted: (json['muted'] as List).map((e) => e as String).toList(),
        anon: json['anon'] as bool,
        demo: json['demo'] as bool? ?? false,
        session: json['session'] as String,
        move: json['move'] as String?,
        votes: (json['votes'] as Map).map((k, v) => MapEntry(k as String, v as int)),
        photoPath: json['photoPath'] as String?,
        lastHandleChangeAt: json['lastHandleChangeAt'] as int?,
        seen: (json['seen'] as List).map((e) => e as String).toList(),
        likes: (json['likes'] as List).map((e) => e as String).toList(),
        activeNights: ((json['activeNights'] as List?) ?? const []).map((e) => e as String).toList(),
        streak: json['streak'] as int? ?? 0,
        placesVisited: ((json['placesVisited'] as List?) ?? const []).map((e) => e as String).toList(),
        displayedTitleThreshold: json['displayedTitleThreshold'] as int?,
        nameBold: json['nameBold'] as bool? ?? false,
        nameItalic: json['nameItalic'] as bool? ?? false,
        nameUnderline: json['nameUnderline'] as bool? ?? false,
        nameCheckbox: json['nameCheckbox'] as bool? ?? false,
        nameColor: json['nameColor'] as int?,
        moveStreak: json['moveStreak'] as int? ?? 0,
        moveStreakDay: json['moveStreakDay'] as String?,
        photoUrl: json['photoUrl'] as String?,
      );
}

/// One of the badges a user can earn by actually contributing (see
/// AppStore.myBadges for the exact thresholds) — separate from the points
/// level/title system. A user can earn many; which ones they show beside
/// their name is a future profile-customization step, not decided here.
class FunkyBadge {
  final String emoji;
  final String label;
  const FunkyBadge(this.emoji, this.label);
}

/// One tier of the points-level title ladder (500 Reliable Source, 1000
/// Verified Stud, … 10000 KING FUNKY) — purely cosmetic, separate from the
/// 8-confirmation report-verification system and the 15-confirmation venue
/// system.
class LevelTitle {
  final int threshold;
  final String title;
  final String emoji;
  const LevelTitle(this.threshold, this.title, this.emoji);
}

const levelTitles = [
  LevelTitle(10000, 'KING FUNKY', '🦁'),
  LevelTitle(9000, 'FUNKY Hall of Fame', '💎👑'),
  LevelTitle(8000, 'Nightlife Legend', '🏆👑'),
  LevelTitle(7000, 'FUNKY Royalty', '👑🔥'),
  LevelTitle(6000, 'After Hours Legend', '🌙👑'),
  LevelTitle(5000, 'FUNKY Elite', '🔥👑'),
  LevelTitle(4000, 'Nightlife Veteran', '🎖️'),
  LevelTitle(3000, 'Certified Menace', '😈'),
  LevelTitle(2500, 'Party Animal', '🐴'),
  LevelTitle(2000, 'Pro Drinker', '🍺'),
  LevelTitle(1500, 'Night Owl', '🦉'),
  LevelTitle(1000, 'Verified Stud', '😎'),
  LevelTitle(500, 'Reliable Source', '✓'),
];

/// The highest title a point total qualifies for, or null below 500.
LevelTitle? levelTitleFor(int points) {
  for (final t in levelTitles) {
    if (points >= t.threshold) return t;
  }
  return null;
}

/// A simple, ever-increasing level number from points — shown next to the
/// title so progress still feels continuous between title tiers (every 250
/// points is another level; 2,840 points is "Level 12").
int levelFor(int points) => (points ~/ 250) + 1;

/// Every title tier a point total has reached, highest first — unlike
/// [levelTitleFor] (just the top one), this is the full list a profile-
/// customization picker needs so someone past KING FUNKY can still choose
/// to show off an earlier title like 'Party Animal'.
List<LevelTitle> levelTitlesFor(int points) => levelTitles.where((t) => points >= t.threshold).toList(growable: false);

// Cosmetic name-styling unlocks — separate from the level titles above,
// each one togglable on its own once unlocked, and every unlocked style
// you've turned on stacks (see AppStore.setNameStyle / Person.nameBold etc).
bool canUseBoldName(int points) => points >= 500;
bool canUseItalicName(int points) => points >= 1000;
bool canUseUnderlineName(int points) => points >= 2000;
bool canUseCheckName(int points) => points >= 5000;
// A custom name color is the cheapest cosmetic to unlock — it's the one
// everybody wants first — but still points-gated like the rest.
const int nameColorUnlockPoints = 250;
bool canUseNameColor(int points) => points >= nameColorUnlockPoints;

/// A person's "going" streak as it should be DISPLAYED right now: the
/// stored count while it's still alive (they voted for a place today's
/// session or yesterday's), and 0 once a whole day has gone by without a
/// vote — that's how "miss a day and you lose it" works without anything
/// having to wake up and reset the number at the 2 PM rollover.
int effectiveMoveStreak(Person p) {
  final day = p.moveStreakDay;
  if (day == null || p.moveStreak <= 0) return 0;
  try {
    final last = DateTime.parse(day);
    final today = DateTime.parse(sessionKey());
    final gap = today.difference(last).inDays;
    return gap <= 1 ? p.moveStreak : 0;
  } catch (_) {
    return 0;
  }
}
