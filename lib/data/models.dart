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

class Report {
  final int cover;
  final bool cops;
  final bool shut;
  const Report({this.cover = 0, this.cops = false, this.shut = false});

  Report copyWith({int? cover, bool? cops, bool? shut}) => Report(
        cover: cover ?? this.cover,
        cops: cops ?? this.cops,
        shut: shut ?? this.shut,
      );

  Map<String, dynamic> toJson() => {'cover': cover, 'cops': cops, 'shut': shut};

  factory Report.fromJson(Map<String, dynamic> json) => Report(
        cover: json['cover'] as int? ?? 0,
        cops: json['cops'] as bool? ?? false,
        shut: json['shut'] as bool? ?? false,
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
  });

  Story copyWith({List<String>? likes}) => Story(
        id: id,
        t: t,
        uid: uid,
        text: text,
        place: place,
        anon: anon,
        session: session,
        views: views,
        likes: likes ?? this.likes,
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
  // else can. Survives the 4 PM reset, same as DMs (rule 3).
  final List<String> friends;
  final List<String> friendRequestsSent; // ids I've asked, awaiting their accept
  final List<String> friendRequestsReceived; // ids who've asked me, awaiting my accept
  final List<String> muted;
  final bool anon;
  final bool demo;

  // Tonight only — cleared by the 4 PM reset per rule 2.
  final String session;
  final String? move; // a place id, "in" (staying in), or null (hasn't picked)
  final Map<String, int> votes; // pollId -> option index
  final Map<String, Report> reports; // placeId -> report
  final List<String> seen;
  final List<String> likes;

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
    required this.reports,
    required this.seen,
    required this.likes,
  });

  Person copyWith({
    String? handle,
    String? bio,
    String? move,
    Map<String, int>? votes,
    Map<String, Report>? reports,
    String? session,
    List<String>? friends,
    List<String>? friendRequestsSent,
    List<String>? friendRequestsReceived,
    bool? anon,
  }) =>
      Person(
        id: id,
        handle: handle ?? this.handle,
        bio: bio ?? this.bio,
        since: since,
        points: points,
        friends: friends ?? this.friends,
        friendRequestsSent: friendRequestsSent ?? this.friendRequestsSent,
        friendRequestsReceived: friendRequestsReceived ?? this.friendRequestsReceived,
        muted: muted,
        anon: anon ?? this.anon,
        demo: demo,
        session: session ?? this.session,
        move: move ?? this.move,
        votes: votes ?? this.votes,
        reports: reports ?? this.reports,
        seen: seen,
        likes: likes,
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
        'reports': reports.map((k, v) => MapEntry(k, v.toJson())),
        'seen': seen,
        'likes': likes,
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
        reports: (json['reports'] as Map).map((k, v) => MapEntry(k as String, Report.fromJson(v as Map<String, dynamic>))),
        seen: (json['seen'] as List).map((e) => e as String).toList(),
        likes: (json['likes'] as List).map((e) => e as String).toList(),
      );
}
