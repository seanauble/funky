/// Mirrors the data model documented in HANDOFF.md ("Data model (as stored
/// inside Claude)") so swapping the mock store for a real backend later is
/// a matter of changing where these records come from, not what shape they
/// are.
library;

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
  final String room; // "main" (area chat) or a place id
  final String uid;
  final String text;
  final bool anon;

  const ChatMessage({
    required this.id,
    required this.t,
    required this.room,
    required this.uid,
    required this.text,
    required this.anon,
  });

  Map<String, dynamic> toJson() => {'id': id, 't': t, 'room': room, 'uid': uid, 'text': text, 'anon': anon};

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        t: json['t'] as int,
        room: json['room'] as String,
        uid: json['uid'] as String,
        text: json['text'] as String,
        anon: json['anon'] as bool,
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
  });

  Story copyWith({List<String>? likes, List<String>? views, List<String>? screenshotBy}) => Story(
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
      );
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
  });

  Person copyWith({
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
        muted: muted,
        anon: anon ?? this.anon,
        demo: demo,
        session: session ?? this.session,
        move: move ?? this.move,
        votes: votes ?? this.votes,
        seen: seen,
        likes: likes,
        activeNights: activeNights ?? this.activeNights,
        streak: streak ?? this.streak,
        placesVisited: placesVisited ?? this.placesVisited,
        photoPath: photoPath ?? this.photoPath,
        lastHandleChangeAt: lastHandleChangeAt ?? this.lastHandleChangeAt,
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
  LevelTitle(10000, 'KING FUNKY', '👊'),
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
