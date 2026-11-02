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
  // The admin-approved picture for this place (see place_photo_suggestions
  // in supabase/phase10.sql) — what the map pin and thumbnails prefer.
  final String? photoUrl;
  // When a party/event/tailgate/frat party happens (phase 33). Null for an
  // ordinary spot or one that's just "tonight". A future one shows under
  // Upcoming until its night, then moves to Tonight.
  final DateTime? startsAt;
  // For an event: what kind ('trivia', 'karaoke', 'live_music', 'dj',
  // 'happy_hour', 'game_watch', 'comedy', 'other').
  final String? eventType;
  // The bar or club an event is held at (trivia night at Charlie's).
  final String? hostPlaceId;
  // A private event (phase 36): the address, exact spot and time are only
  // for people who entered the host's code. Until then [address] is a
  // placeholder, the pin is rough, and [timeHidden] is true ([startsAt] only
  // carries the night).
  final bool isPrivate;
  final bool timeHidden;
  // Posted by the owner of the bar it's at — verified right away (phase 41).
  final bool official;
  // The owner's deal for a bar or club ("No cover before 10"), or null.
  final String? deal;
  // What this bar or club gives for a FUNKY reward pass ("Free cover"), or
  // null when it isn't taking part (phase 42).
  final String? reward;
  // A party's price to get in, e.g. 10.0 (phase 43), or null.
  final double? entryPrice;
  // Who sees how many are going: 'public' (everyone) or 'hint' (only the
  // hosts; everyone else sees a few faces).
  final String goingVisibility;

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
    this.photoUrl,
    this.startsAt,
    this.eventType,
    this.hostPlaceId,
    this.isPrivate = false,
    this.timeHidden = false,
    this.official = false,
    this.deal,
    this.reward,
    this.entryPrice,
    this.goingVisibility = 'public',
  });

  bool get hidesGoingCount => goingVisibility == 'hint';

  /// The same place with the owner's deal or reward changed (pass null in
  /// the function to clear it).
  Place withOwnerInfo({String? Function()? deal, String? Function()? reward}) => Place(
        id: id,
        name: name,
        kind: kind,
        lat: lat,
        lng: lng,
        address: address,
        by: by,
        t: t,
        session: session,
        coverPhotoPath: coverPhotoPath,
        coverUrl: coverUrl,
        photoUrl: photoUrl,
        startsAt: startsAt,
        eventType: eventType,
        hostPlaceId: hostPlaceId,
        isPrivate: isPrivate,
        timeHidden: timeHidden,
        official: official,
        deal: deal == null ? this.deal : deal(),
        reward: reward == null ? this.reward : reward(),
        entryPrice: entryPrice,
        goingVisibility: goingVisibility,
      );

  /// The night (2 PM to 2 PM) it happens on, e.g. "2026-11-07", or null.
  String? get night => startsAt == null ? null : sessionKey(startsAt!);

  /// The start time when it's known and not locked behind a code.
  DateTime? get shownTime => timeHidden ? null : startsAt;

  /// The same place with its private details filled in (or swapped).
  Place withDetails({String? address, double? lat, double? lng, DateTime? startsAt, bool? timeHidden}) => Place(
        id: id,
        name: name,
        kind: kind,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        address: address ?? this.address,
        by: by,
        t: t,
        session: session,
        coverPhotoPath: coverPhotoPath,
        coverUrl: coverUrl,
        photoUrl: photoUrl,
        startsAt: startsAt ?? this.startsAt,
        eventType: eventType,
        hostPlaceId: hostPlaceId,
        isPrivate: isPrivate,
        timeHidden: timeHidden ?? this.timeHidden,
        official: official,
        deal: deal,
        reward: reward,
        entryPrice: entryPrice,
        goingVisibility: goingVisibility,
      );

  /// The same place somewhere else on the map (an admin moved its pin).
  Place movedTo(double newLat, double newLng) => Place(
        id: id,
        name: name,
        kind: kind,
        lat: newLat,
        lng: newLng,
        address: address,
        by: by,
        t: t,
        session: session,
        coverPhotoPath: coverPhotoPath,
        coverUrl: coverUrl,
        photoUrl: photoUrl,
        startsAt: startsAt,
        eventType: eventType,
        hostPlaceId: hostPlaceId,
        isPrivate: isPrivate,
        timeHidden: timeHidden,
        official: official,
        deal: deal,
        reward: reward,
        entryPrice: entryPrice,
        goingVisibility: goingVisibility,
      );

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
        'photoUrl': photoUrl,
        'startsAt': startsAt?.millisecondsSinceEpoch,
        'eventType': eventType,
        'hostPlaceId': hostPlaceId,
        'isPrivate': isPrivate,
        'timeHidden': timeHidden,
        'official': official,
        'deal': deal,
        'reward': reward,
        'entryPrice': entryPrice,
        'goingVisibility': goingVisibility,
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
        photoUrl: json['photoUrl'] as String?,
        startsAt: json['startsAt'] is int ? DateTime.fromMillisecondsSinceEpoch(json['startsAt'] as int) : null,
        eventType: json['eventType'] as String?,
        hostPlaceId: json['hostPlaceId'] as String?,
        isPrivate: json['isPrivate'] == true,
        timeHidden: json['timeHidden'] == true,
        official: json['official'] == true,
        deal: json['deal'] as String?,
        reward: json['reward'] as String?,
        entryPrice: (json['entryPrice'] as num?)?.toDouble(),
        goingVisibility: json['goingVisibility'] == 'hint' ? 'hint' : 'public',
      );
}

/// A private event's real address, spot and time (only for its guests and
/// host). [passcode] is only known to the host.
class PrivateEventDetails {
  final String placeId;
  final String? address;
  final double? lat;
  final double? lng;
  final DateTime? startsAt;
  final String? passcode;
  // 'shared' (one code for everyone) or 'personal' (a code for each
  // person, each used once) — phase 43.
  final String codeMode;
  const PrivateEventDetails({required this.placeId, this.address, this.lat, this.lng, this.startsAt, this.passcode, this.codeMode = 'shared'});

  bool get personalCodes => codeMode == 'personal';
}

/// Someone on a private event's guest list and their RSVP:
/// 'going', 'maybe', 'cant', or 'unlocked' (entered the code, no answer yet).
class EventGuest {
  final String uid; // 'me' for you
  final String status;
  final int t;
  // When the door checked them in (phase 43), and who let them in.
  final DateTime? checkedInAt;
  final String? letInBy;
  const EventGuest({required this.uid, required this.status, required this.t, this.checkedInAt, this.letInBy});

  EventGuest withCheckIn(DateTime? at) => EventGuest(uid: uid, status: at != null ? 'going' : status, t: t, checkedInAt: at, letInBy: letInBy);
}

/// One message in a party or event's chat.
class EventMessage {
  final String id;
  final String placeId;
  final String uid; // 'me' for you
  final String text;
  final int t;
  final ChatCard? card;
  const EventMessage({required this.id, required this.placeId, required this.uid, required this.text, required this.t, this.card});

  EventMessage withCard(ChatCard? c) => EventMessage(id: id, placeId: placeId, uid: uid, text: text, t: t, card: c);
}

/// What an event at a bar or club is.
const placeEventTypes = <(String, String, String)>[
  ('trivia', 'Trivia', '🧠'),
  ('karaoke', 'Karaoke', '🎤'),
  ('live_music', 'Live music', '🎸'),
  ('dj', 'DJ night', '🎧'),
  ('happy_hour', 'Happy hour', '🍻'),
  ('game_watch', 'Game watch', '🏈'),
  ('comedy', 'Comedy', '😂'),
  ('other', 'Other', '✨'),
];

String placeEventTypeLabel(String? type) {
  for (final t in placeEventTypes) {
    if (t.$1 == type) return t.$2;
  }
  return 'Event';
}

String placeEventTypeEmoji(String? type) {
  for (final t in placeEventTypes) {
    if (t.$1 == type) return t.$3;
  }
  return '✨';
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
  // A DM sent by swiping up on someone's Story: which Story it answers, and
  // enough of it (caption, the picture's storage path) to show a small
  // preview above the message even after the Story itself is gone.
  final String? storyId;
  final String? storyText;
  final String? storyMediaPath;
  final bool storyIsVideo;
  // Live Chat extras (phase 33): the message this one answers (with a copy
  // of its words and who said it, so the quote survives it being deleted),
  // a shared spot, a shared poll, and a GIF.
  final String? replyToId;
  final String? replyText;
  final String? replyHandle;
  final String? sharedPlaceId;
  final String? pollId;
  final String? gifUrl;
  // How far a Live Chat message reaches: the sender's own radius when they
  // sent it (an admin's can reach much further than 50 miles). Someone sees
  // it if it's inside their radius OR they're inside its reach.
  final int? reachMiles;
  // A payment card, or the "asked to go" / "you're in" cards (phase 43).
  final ChatCard? card;

  bool get isStoryReply => storyId != null || storyMediaPath != null || storyText != null;
  bool get isReply => replyToId != null || replyText != null;

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
    this.storyId,
    this.storyText,
    this.storyMediaPath,
    this.storyIsVideo = false,
    this.replyToId,
    this.replyText,
    this.replyHandle,
    this.sharedPlaceId,
    this.pollId,
    this.gifUrl,
    this.reachMiles,
    this.card,
  });

  bool get hasMedia => mediaType != null && (mediaPath != null || mediaUrl != null);

  ChatMessage copyWith({
    String? id,
    Map<String, List<String>>? reactions,
    String? status,
    String? mediaUrl,
    ChatCard? card,
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
        storyId: storyId,
        storyText: storyText,
        storyMediaPath: storyMediaPath,
        storyIsVideo: storyIsVideo,
        replyToId: replyToId,
        replyText: replyText,
        replyHandle: replyHandle,
        sharedPlaceId: sharedPlaceId,
        pollId: pollId,
        gifUrl: gifUrl,
        reachMiles: reachMiles,
        card: card ?? this.card,
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
        'storyId': storyId,
        'storyText': storyText,
        'storyMediaPath': storyMediaPath,
        'storyIsVideo': storyIsVideo,
        'replyToId': replyToId,
        'replyText': replyText,
        'replyHandle': replyHandle,
        'sharedPlaceId': sharedPlaceId,
        'pollId': pollId,
        'gifUrl': gifUrl,
        'reachMiles': reachMiles,
        if (card != null) 'card': card!.toJson(),
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
        storyId: json['storyId'] as String?,
        storyText: json['storyText'] as String?,
        storyMediaPath: json['storyMediaPath'] as String?,
        storyIsVideo: json['storyIsVideo'] as bool? ?? false,
        replyToId: json['replyToId'] as String?,
        replyText: json['replyText'] as String?,
        replyHandle: json['replyHandle'] as String?,
        sharedPlaceId: json['sharedPlaceId'] as String?,
        pollId: json['pollId'] as String?,
        gifUrl: json['gifUrl'] as String?,
        reachMiles: (json['reachMiles'] as num?)?.toInt(),
        card: json['card'] is Map ? ChatCard.fromJson((json['card'] as Map).cast<String, dynamic>()) : null,
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
  // Where the poster was when they posted — what keeps an Area story inside
  // the area it was posted in. Null for older stories.
  final double? lat;
  final double? lng;
  // Where the photo/video lives in the server's stories bucket (someone
  // else's Story) — lets a DM reply show a preview of it later.
  final String? mediaPath;

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
    this.lat,
    this.lng,
    this.mediaPath,
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
        lat: lat,
        lng: lng,
        mediaPath: mediaPath,
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
        'lat': lat,
        'lng': lng,
        'mediaPath': mediaPath,
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
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        mediaPath: json['mediaPath'] as String?,
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
  // An animated name, like the old Call of Duty clan tags: 'cycle' flashes
  // through colors (5,000 points), 'rain' is a moving rainbow (10,000).
  // One at a time; null for none. See canUseCycleName / canUseRainName.
  final String? nameEffect;

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
    this.nameEffect,
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
    bool clearPhotoPath = false,
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
    String? nameEffect,
    bool clearNameEffect = false,
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
        photoPath: clearPhotoPath ? null : (photoPath ?? this.photoPath),
        lastHandleChangeAt: clearLastHandleChange ? null : (lastHandleChangeAt ?? this.lastHandleChangeAt),
        displayedTitleThreshold: clearDisplayedTitleThreshold ? null : (displayedTitleThreshold ?? this.displayedTitleThreshold),
        nameBold: nameBold ?? this.nameBold,
        nameItalic: nameItalic ?? this.nameItalic,
        nameUnderline: nameUnderline ?? this.nameUnderline,
        nameCheckbox: nameCheckbox ?? this.nameCheckbox,
        nameColor: clearNameColor ? null : (nameColor ?? this.nameColor),
        nameEffect: clearNameEffect ? null : (nameEffect ?? this.nameEffect),
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
        'nameEffect': nameEffect,
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
        nameEffect: json['nameEffect'] as String?,
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
// Animated names, the top unlocks: a color-cycling name, then rainbow.
const int cycleNamePoints = 5000;
const int rainNamePoints = 10000;
bool canUseCycleName(int points) => points >= cycleNamePoints;
bool canUseRainName(int points) => points >= rainNamePoints;
bool canUseNameEffect(String? effect, int points) => switch (effect) {
      'cycle' => canUseCycleName(points),
      'rain' => canUseRainName(points),
      _ => false,
    };
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

/// One place someone posted a Story at, for the "places been" flex.
class PlaceBeen {
  final String placeId;
  final String name;
  final String? kind; // 'bar', 'club', 'party'…
  final int nights;
  final DateTime? last;
  const PlaceBeen({required this.placeId, required this.name, this.kind, this.nights = 1, this.last});
}

/// Someone's places been: how many, and (for friends and yourself) which.
class PlacesBeen {
  final int count;
  final int nights;
  final List<PlaceBeen>? places; // null when you can only see the count
  const PlacesBeen({required this.count, required this.nights, this.places});
}

/// Someone asking to run (or running) a bar or club's page.
class PlaceClaim {
  final String id;
  final String placeId;
  final String uid; // 'me' for you
  final String status; // 'pending', 'approved', 'rejected'
  final String? role;
  final String? contact;
  final String? note;
  final DateTime createdAt;
  const PlaceClaim({
    required this.id,
    required this.placeId,
    required this.uid,
    required this.status,
    this.role,
    this.contact,
    this.note,
    required this.createdAt,
  });
}

/// Someone who joined with your invite code (phase 42).
class ReferralFriend {
  final String uid; // their profile id
  final DateTime joinedAt;
  final DateTime? countedAt; // null until they're active
  const ReferralFriend({required this.uid, required this.joinedAt, this.countedAt});
  bool get counts => countedAt != null;
}

/// A free-night-out pass from bringing in friends (phase 42).
class RewardPass {
  final String id;
  final DateTime earnedAt;
  final DateTime? usedAt;
  final String? usedPlaceId;
  final String? usedReward;
  const RewardPass({required this.id, required this.earnedAt, this.usedAt, this.usedPlaceId, this.usedReward});
  bool get used => usedAt != null;
}

/// Your invite code, who you brought in, and your passes (phase 42).
class ReferralStatus {
  final String? code;
  final int perReward;
  final String? invitedBy; // who brought you in ('me'-style id), or null
  final bool invitedByCounts;
  final bool canEnterCode;
  final List<ReferralFriend> invited;
  final List<RewardPass> rewards;
  const ReferralStatus({
    this.code,
    this.perReward = 5,
    this.invitedBy,
    this.invitedByCounts = false,
    this.canEnterCode = false,
    this.invited = const [],
    this.rewards = const [],
  });

  int get counted => invited.where((f) => f.counts).length;
  int get waiting => invited.length - counted;

  /// Friends toward the next pass (0 to perReward - 1).
  int get towardNext => counted % perReward;
  List<RewardPass> get unusedRewards => rewards.where((r) => !r.used).toList();
}

/// Someone who tapped "I paid" on a payment card.
class PayMark {
  final String uid; // 'me' for you
  final String via; // 'venmo', 'cashapp', 'paypal', 'zelle', 'applecash', 'cash', 'other'
  final DateTime at;
  const PayMark({required this.uid, required this.via, required this.at});
}

/// A card in a chat (phase 43):
///  * 'pay'   — "Pay me $10" with buttons for the sender's payment apps
///  * 'ask'   — someone asked to go to your private event
///  * 'entry' — you were let into a private event
class ChatCard {
  final String type;
  final String? amount; // "10" or "10.50"
  final String? note;
  final Map<String, String> apps; // 'venmo' -> 'mike-delta'
  final String? placeId;
  final String? name; // the event's name (ask / entry)
  final List<PayMark> paid;
  const ChatCard({
    required this.type,
    this.amount,
    this.note,
    this.apps = const {},
    this.placeId,
    this.name,
    this.paid = const [],
  });

  bool get isPay => type == 'pay';
  bool get isAsk => type == 'ask';
  bool get isEntry => type == 'entry';

  PayMark? paidBy(String uid) {
    for (final m in paid) {
      if (m.uid == uid) return m;
    }
    return null;
  }

  /// [asMe] turns your real account id into 'me'.
  factory ChatCard.fromJson(Map<String, dynamic> j, {String Function(String)? asMe}) {
    final apps = <String, String>{};
    final rawApps = j['apps'];
    if (rawApps is Map) {
      for (final e in rawApps.entries) {
        if (e.value is String && (e.value as String).isNotEmpty) apps[e.key.toString()] = e.value as String;
      }
    }
    final paid = <PayMark>[];
    final rawPaid = j['paid'];
    if (rawPaid is List) {
      for (final x in rawPaid) {
        if (x is! Map) continue;
        final uid = x['uid'] as String?;
        if (uid == null) continue;
        paid.add(PayMark(
          uid: asMe == null ? uid : asMe(uid),
          via: (x['via'] as String?) ?? 'other',
          at: DateTime.tryParse((x['at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ));
      }
    }
    final amt = j['amount'];
    return ChatCard(
      type: (j['type'] as String?) ?? 'pay',
      amount: amt?.toString(),
      note: j['note'] as String?,
      apps: apps,
      placeId: j['place_id'] as String?,
      name: j['name'] as String?,
      paid: paid,
    );
  }

  /// For saving on the phone (keeps 'me').
  Map<String, dynamic> toJson() => {
        'type': type,
        if (amount != null) 'amount': amount,
        if (note != null) 'note': note,
        'apps': apps,
        if (placeId != null) 'place_id': placeId,
        if (name != null) 'name': name,
        'paid': [for (final m in paid) {'uid': m.uid, 'via': m.via, 'at': m.at.toUtc().toIso8601String()}],
      };

  /// What goes to the server for a new payment card.
  Map<String, dynamic> toServer() => {
        'type': 'pay',
        if (amount != null) 'amount': amount,
        if (note != null) 'note': note,
        'apps': apps,
        if (placeId != null) 'place_id': placeId,
      };
}

/// Your usernames on payment apps (phase 43). Empty strings are left out.
class PaymentHandles {
  final String? venmo;
  final String? cashapp;
  final String? paypal;
  final String? zelle;
  final String? applecash;
  const PaymentHandles({this.venmo, this.cashapp, this.paypal, this.zelle, this.applecash});

  Map<String, String> get apps => {
        if ((venmo ?? '').isNotEmpty) 'venmo': venmo!,
        if ((cashapp ?? '').isNotEmpty) 'cashapp': cashapp!,
        if ((paypal ?? '').isNotEmpty) 'paypal': paypal!,
        if ((zelle ?? '').isNotEmpty) 'zelle': zelle!,
        if ((applecash ?? '').isNotEmpty) 'applecash': applecash!,
      };

  bool get isEmpty => apps.isEmpty;
}

/// A one-time code for a private event (phase 43).
class EventCode {
  final String id;
  final String placeId;
  final String code;
  final String? label;
  final String? createdBy; // 'me' for you
  final DateTime createdAt;
  final String? usedBy;
  final DateTime? usedAt;
  const EventCode({
    required this.id,
    required this.placeId,
    required this.code,
    this.label,
    this.createdBy,
    required this.createdAt,
    this.usedBy,
    this.usedAt,
  });
  bool get used => usedBy != null;
}

/// Someone who asked to go to a private event (phase 43).
/// status: 'asked', 'pay_sent', 'paid', 'in', 'declined'.
class EventRequest {
  final String placeId;
  final String uid;
  final String status;
  final String? note;
  final String? handledBy;
  final DateTime updatedAt;
  const EventRequest({required this.placeId, required this.uid, required this.status, this.note, this.handledBy, required this.updatedAt});
}

/// Who's going, the way the host wants it shown (phase 43).
class GoingPreview {
  final int? count; // null when the host keeps the number to themselves
  final List<String> faces;
  final bool more;
  final bool hidden;
  const GoingPreview({this.count, this.faces = const [], this.more = false, this.hidden = false});
}
