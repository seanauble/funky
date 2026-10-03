import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'geo.dart';
import 'mock_data.dart';
import 'models.dart';
import 'session.dart';

const _storageKey = 'funky.store.v1';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// A lightweight local hash — NOT real cryptographic security. This whole
/// app is a mock store with no backend to actually authenticate against, so
/// there's nothing a strong hash would meaningfully protect; this just
/// keeps the password from sitting around in plain text in local storage.
/// Swap this (and the account fields below) for real server-side auth
/// before this app ever talks to a backend.
String _hashPassword(String password, String salt) {
  final bytes = utf8.encode('$salt:$password');
  int h1 = 0x811c9dc5;
  for (final b in bytes) {
    h1 = ((h1 ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  int h2 = 0x1000193 ^ bytes.length;
  for (final b in bytes.reversed) {
    h2 = ((h2 ^ b) * 0x811c9dc5) & 0xFFFFFFFF;
  }
  return '${h1.toRadixString(16)}${h2.toRadixString(16)}';
}

String _newSalt() {
  final rand = Random.secure();
  return List<int>.generate(16, (_) => rand.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

enum LocationStatus { unknown, requesting, granted, denied }

class RankedPlace {
  final Place place;
  final double distance;
  final int going;
  final int heat; // 0-3
  final int score; // raw activity score the heat bucket and map glow are built from
  final Report? cover;

  RankedPlace({required this.place, required this.distance, required this.going, required this.heat, required this.score, this.cover});

  String get id => place.id;
  String get name => place.name;
  PlaceKind get kind => place.kind;
  String get address => place.address;
}

List<T> _dedupeById<T>(List<T> items, String Function(T) idOf) {
  final seen = <String>{};
  final out = <T>[];
  for (final item in items) {
    final id = idOf(item);
    if (seen.contains(id)) continue;
    seen.add(id);
    out.add(item);
  }
  return out;
}

/// Ports the prototype's mock store (store.tsx in the Expo build) to a
/// Flutter ChangeNotifier: same 4 PM reset logic (rule 2/3), same ranking
/// math, same actions — just Dart instead of TypeScript.
class AppStore extends ChangeNotifier {
  bool loaded = false;
  bool justReset = false;

  Person me = freshMe();
  late Map<String, Person> people;
  late List<Place> places;
  late List<Poll> polls;
  late List<ChatMessage> messages;
  late List<Story> stories;

  LatLng? location;
  LocationStatus locationStatus = LocationStatus.unknown;

  // Account — browsing FUNKY is always anonymous and free; you only need
  // one of these to post a Story/poll/place or send a message (see
  // requireAccountThen in lib/screens/account_screen.dart, which is what
  // actually enforces that gate from the UI). Survives the 4 PM reset and
  // app restarts, same as friends.
  String? accountEmail;
  String? _passwordHash;
  String? _passwordSalt;
  bool signedIn = false;

  bool get hasAccount => accountEmail != null && _passwordHash != null;

  AppStore() {
    final session = sessionKey();
    people = {for (final p in samplePeople(session)) p.id: p};
    places = sampleWithSession(session);
    polls = samplePolls(session);
    messages = sampleMessages();
    stories = sampleStories(session);

    // Demo seed so Friends isn't empty on a fresh install: p1 is already a
    // friend (their Stories show unlocked), p2 has a pending request waiting
    // on you (so the notification bell has something to show immediately).
    me = me.copyWith(friends: const ['p1'], friendRequestsReceived: const ['p2']);
    if (people.containsKey('p1')) {
      people = {...people, 'p1': people['p1']!.copyWith(friends: const ['me'])};
    }
    if (people.containsKey('p2')) {
      people = {...people, 'p2': people['p2']!.copyWith(friendRequestsSent: const ['me'])};
    }

    // Demo seed so the sample polls don't start sitting at a dead 0% —
    // give the demo people a few opinions already cast tonight.
    if (people.containsKey('p1')) {
      people = {...people, 'p1': people['p1']!.copyWith(votes: const {'rowan-out': 0})};
    }
    if (people.containsKey('p2')) {
      people = {...people, 'p2': people['p2']!.copyWith(votes: const {'rowan-out': 0, 'ac-best': 1})};
    }
    if (people.containsKey('p3')) {
      people = {...people, 'p3': people['p3']!.copyWith(votes: const {'ac-best': 0})};
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      final currentSession = sessionKey();
      if (raw != null) {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        final storedSession = parsed['session'] as String?;
        final parsedMe = Person.fromJson(parsed['me'] as Map<String, dynamic>);
        final parsedPlaces = (parsed['places'] as List).map((e) => Place.fromJson(e as Map<String, dynamic>)).toList();
        final parsedPolls = (parsed['polls'] as List).map((e) => Poll.fromJson(e as Map<String, dynamic>)).toList();
        final parsedMessages = (parsed['messages'] as List).map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList();
        final parsedStories = (parsed['stories'] as List).map((e) => Story.fromJson(e as Map<String, dynamic>)).toList();

        // Account info is never tied to tonight's session — it survives
        // same as friends/DMs, read unconditionally either way below.
        accountEmail = parsed['accountEmail'] as String?;
        _passwordHash = parsed['passwordHash'] as String?;
        _passwordSalt = parsed['passwordSalt'] as String?;
        signedIn = parsed['signedIn'] as bool? ?? false;

        if (storedSession == currentSession) {
          me = parsedMe;
          places = _dedupeById([...places, ...parsedPlaces], (p) => p.id);
          polls = _dedupeById([...polls, ...parsedPolls], (p) => p.id);
          messages = _dedupeById([...messages, ...parsedMessages], (m) => m.id);
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
        } else {
          // Stale night — carry over only what survives the reset (rule 3).
          // Friends (and pending requests) stay, same as DMs — only the
          // tonight-only stuff (move, votes, reports) gets wiped.
          me = Person(
            id: parsedMe.id,
            handle: parsedMe.handle,
            bio: parsedMe.bio,
            since: parsedMe.since,
            points: parsedMe.points,
            friends: parsedMe.friends,
            friendRequestsSent: parsedMe.friendRequestsSent,
            friendRequestsReceived: parsedMe.friendRequestsReceived,
            muted: parsedMe.muted,
            anon: parsedMe.anon,
            session: currentSession,
            move: null,
            votes: const {},
            reports: const {},
            seen: const [],
            likes: const [],
          );
          justReset = true;
        }
      }
    } catch (_) {
      // Corrupt or missing storage — just start fresh, same as a new install.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    if (!loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = {
        'session': sessionKey(),
        'me': me.toJson(),
        'places': places.where((p) => p.by == 'me').map((p) => p.toJson()).toList(),
        'polls': polls.where((p) => p.by == 'me').map((p) => p.toJson()).toList(),
        'messages': messages.where((m) => m.uid == 'me').map((m) => m.toJson()).toList(),
        'stories': stories.where((s) => s.uid == 'me').map((s) => s.toJson()).toList(),
        'accountEmail': accountEmail,
        'passwordHash': _passwordHash,
        'passwordSalt': _passwordSalt,
        'signedIn': signedIn,
      };
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (_) {
      // Non-fatal — worst case this session's additions don't survive a reload.
    }
  }

  Future<void> requestLocation() async {
    locationStatus = LocationStatus.requesting;
    notifyListeners();
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        locationStatus = LocationStatus.denied;
        notifyListeners();
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        locationStatus = LocationStatus.denied;
        notifyListeners();
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      location = LatLng(pos.latitude, pos.longitude);
      locationStatus = LocationStatus.granted;
      notifyListeners();
    } catch (_) {
      locationStatus = LocationStatus.denied;
      notifyListeners();
    }
  }

  /// A manual override for trying the app away from real sample places —
  /// the native equivalent of the prototype's "testing only" town picker.
  void useTestLocation(LatLng loc) {
    location = loc;
    locationStatus = LocationStatus.granted;
    notifyListeners();
  }

  List<RankedPlace> get rankedPlaces {
    final here = location ?? defaultLocation;
    final allPeople = {...people, 'me': me};
    final result = places.where((p) => near(here, LatLng(p.lat, p.lng))).map((p) {
      final going = allPeople.values.where((person) => person.move == p.id).length;
      final roomMsgCount = messages.where((m) => m.room == p.id).length;
      final storyCount = stories.where((s) => s.place == p.id).length;
      final score = going * 3 + roomMsgCount + storyCount * 2;
      final heat = score >= 12 ? 3 : (score >= 5 ? 2 : (score >= 1 ? 1 : 0));
      final cover = me.reports[p.id];
      return RankedPlace(place: p, distance: milesBetween(here, LatLng(p.lat, p.lng)), going: going, heat: heat, score: score, cover: cover);
    }).toList();
    result.sort((a, b) {
      if (a.heat != b.heat) return b.heat.compareTo(a.heat);
      if (a.going != b.going) return b.going.compareTo(a.going);
      return a.distance.compareTo(b.distance);
    });
    return result;
  }

  List<Poll> get visiblePolls {
    final here = location ?? defaultLocation;
    return polls.where((p) => near(here, LatLng(p.lat, p.lng))).toList();
  }

  List<ChatMessage> messagesFor(String room) {
    final list = messages.where((m) => m.room == room).toList();
    list.sort((a, b) => a.t.compareTo(b.t));
    return list;
  }

  List<Story> storiesFor(String ring) => stories.where((s) => s.place == ring).toList();

  List<Story> get myStories {
    final mine = stories.where((s) => s.uid == 'me').toList();
    mine.sort((a, b) => b.t.compareTo(a.t));
    return mine;
  }

  /// Every Story a given person has posted (newest first) — used on their
  /// profile. The caller decides whether to actually show these; see
  /// canSeeStoriesOf below for the friends-only gate.
  List<Story> storiesByUser(String uid) {
    final theirs = stories.where((s) => s.uid == uid).toList();
    theirs.sort((a, b) => b.t.compareTo(a.t));
    return theirs;
  }

  /// Looks a person up by id, including 'me' (who isn't in the people map).
  Person? personById(String id) => id == 'me' ? me : people[id];

  bool isFriendsWith(String personId) => personId == 'me' || me.friends.contains(personId);

  bool hasSentRequestTo(String personId) => me.friendRequestsSent.contains(personId);

  bool hasRequestFrom(String personId) => me.friendRequestsReceived.contains(personId);

  /// Friends-only gate for "old Stories" on someone's profile (your own
  /// profile is always visible to you).
  bool canSeeStoriesOf(String personId) => isFriendsWith(personId);

  List<Person> get incomingFriendRequests =>
      me.friendRequestsReceived.map(personById).whereType<Person>().toList();

  List<Person> get outgoingFriendRequests =>
      me.friendRequestsSent.map(personById).whereType<Person>().toList();

  int get pendingFriendRequestCount => me.friendRequestsReceived.length;

  void sendFriendRequest(String personId) {
    if (personId == 'me' || isFriendsWith(personId) || hasSentRequestTo(personId)) return;
    me = me.copyWith(friendRequestsSent: [...me.friendRequestsSent, personId]);
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsReceived: [...them.friendRequestsReceived, 'me'])};
    }
    notifyListeners();
    _persist();
  }

  void cancelFriendRequest(String personId) {
    me = me.copyWith(friendRequestsSent: me.friendRequestsSent.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsReceived: them.friendRequestsReceived.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
  }

  void acceptFriendRequest(String personId) {
    if (!me.friendRequestsReceived.contains(personId)) return;
    me = me.copyWith(
      friendRequestsReceived: me.friendRequestsReceived.where((id) => id != personId).toList(),
      friends: [...me.friends, personId],
    );
    final them = people[personId];
    if (them != null) {
      people = {
        ...people,
        personId: them.copyWith(
          friendRequestsSent: them.friendRequestsSent.where((id) => id != 'me').toList(),
          friends: [...them.friends, 'me'],
        ),
      };
    }
    notifyListeners();
    _persist();
  }

  void declineFriendRequest(String personId) {
    me = me.copyWith(friendRequestsReceived: me.friendRequestsReceived.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsSent: them.friendRequestsSent.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
  }

  void removeFriend(String personId) {
    me = me.copyWith(friends: me.friends.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friends: them.friends.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
  }

  void setHandle(String handle) {
    me = me.copyWith(handle: handle);
    notifyListeners();
    _persist();
  }

  void setBio(String bio) {
    me = me.copyWith(bio: bio);
    notifyListeners();
    _persist();
  }

  void setAnon(bool value) {
    me = me.copyWith(anon: value);
    notifyListeners();
    _persist();
  }

  void setMove(String placeIdOrIn) {
    me = me.copyWith(move: placeIdOrIn);
    notifyListeners();
    _persist();
  }

  void votePoll(String pollId, int optionIndex) {
    final votes = {...me.votes, pollId: optionIndex};
    me = me.copyWith(votes: votes);
    notifyListeners();
    _persist();
  }

  /// Real per-option vote tallies for a poll — this is what PollBars uses to
  /// draw the fill/percentage. It used to always be fed a zero-filled list
  /// (poll bars never moved no matter what you tapped), which is why voting
  /// looked completely broken.
  List<int> pollCounts(Poll poll) {
    final allPeople = {...people, 'me': me};
    final counts = List<int>.filled(poll.options.length, 0);
    for (final p in allPeople.values) {
      final v = p.votes[poll.id];
      if (v != null && v >= 0 && v < counts.length) counts[v]++;
    }
    return counts;
  }

  Place addPlace(String name, PlaceKind kind, String address) {
    final here = location ?? defaultLocation;
    final place = Place(
      id: 'place_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      kind: kind,
      lat: here.lat,
      lng: here.lng,
      address: address,
      by: 'me',
      t: DateTime.now().millisecondsSinceEpoch,
      session: sessionKey(),
    );
    places = [...places, place];
    notifyListeners();
    _persist();
    return place;
  }

  Poll addPoll(String q, List<String> options) {
    final here = location ?? defaultLocation;
    final poll = Poll(
      id: 'poll_${DateTime.now().millisecondsSinceEpoch}',
      q: q,
      options: options,
      lat: here.lat,
      lng: here.lng,
      by: 'me',
      t: DateTime.now().millisecondsSinceEpoch,
      session: sessionKey(),
    );
    polls = [...polls, poll];
    notifyListeners();
    _persist();
    return poll;
  }

  void sendMessage(String room, String text, bool anon) {
    final message = ChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      room: room,
      uid: 'me',
      text: text,
      anon: anon,
    );
    messages = [...messages, message];
    notifyListeners();
    _persist();
  }

  void addStory({String? text, String? imagePath, String? videoPath, required String place, required bool anon}) {
    final story = Story(
      id: 'story_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      uid: 'me',
      text: text,
      imagePath: imagePath,
      videoPath: videoPath,
      place: place,
      anon: anon,
      session: sessionKey(),
      // Seed a few of tonight's demo people as having already seen it, so a
      // freshly-posted Story doesn't just sit at a dead "0 views" — same
      // reasoning as the poll-vote and friend-request seeds above.
      views: (people.keys.toList()..shuffle()).take(2).toList(),
      likes: const [],
    );
    stories = [...stories, story];
    notifyListeners();
    _persist();
  }

  void likeStory(String id) {
    stories = stories.map((s) {
      if (s.id == id && !s.likes.contains('me')) {
        return s.copyWith(likes: [...s.likes, 'me']);
      }
      return s;
    }).toList();
    notifyListeners();
    _persist();
  }

  /// Marks a Story as seen by 'me' — called once per Story shown in the
  /// Story viewer. No-op (and no rebuild) if already recorded.
  void recordStoryView(String storyId) {
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1 || stories[i].views.contains('me')) return;
    final updated = stories[i].copyWith(views: [...stories[i].views, 'me']);
    stories = [...stories]..[i] = updated;
    notifyListeners();
    _persist();
  }

  /// Marks a Story as screenshotted by 'me' — fed by the native iOS/Android
  /// screenshot notification while the Story viewer is open (see
  /// lib/services/screenshot_detector.dart). The poster only ever sees a
  /// count, never who took it.
  void recordScreenshot(String storyId) {
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1 || stories[i].screenshotBy.contains('me')) return;
    final updated = stories[i].copyWith(screenshotBy: [...stories[i].screenshotBy, 'me']);
    stories = [...stories]..[i] = updated;
    notifyListeners();
    _persist();
  }

  void reportPlace(String placeId, {int? cover, bool? cops, bool? shut}) {
    final current = me.reports[placeId] ?? const Report();
    final updated = current.copyWith(cover: cover, cops: cops, shut: shut);
    final reports = {...me.reports, placeId: updated};
    me = me.copyWith(reports: reports);
    notifyListeners();
    _persist();
  }

  void dismissResetBanner() {
    justReset = false;
    notifyListeners();
  }

  // --- Account -------------------------------------------------------
  // See the class-level doc on `accountEmail` above for what this does
  // and doesn't guarantee. All four methods return null on success, or a
  // user-facing error string on failure.

  String? validateEmail(String email) {
    if (!_emailPattern.hasMatch(email.trim())) return 'Enter a real email address.';
    return null;
  }

  String? validatePassword(String password) {
    if (password.length < 8) return 'Use at least 8 characters.';
    return null;
  }

  String? signUp(String email, String password) {
    final emailError = validateEmail(email);
    if (emailError != null) return emailError;
    final pwError = validatePassword(password);
    if (pwError != null) return pwError;
    final salt = _newSalt();
    accountEmail = email.trim().toLowerCase();
    _passwordSalt = salt;
    _passwordHash = _hashPassword(password, salt);
    signedIn = true;
    notifyListeners();
    _persist();
    return null;
  }

  String? signIn(String email, String password) {
    if (!hasAccount) return 'No account on this device yet — create one first.';
    final matches = email.trim().toLowerCase() == accountEmail && _hashPassword(password, _passwordSalt!) == _passwordHash;
    if (!matches) return 'Email or password is wrong.';
    signedIn = true;
    notifyListeners();
    _persist();
    return null;
  }

  void signOut() {
    signedIn = false;
    notifyListeners();
    _persist();
  }

  String? changeEmail(String newEmail, String currentPassword) {
    if (!signedIn || !hasAccount) return 'Log in first.';
    if (_hashPassword(currentPassword, _passwordSalt!) != _passwordHash) return 'Current password is wrong.';
    final error = validateEmail(newEmail);
    if (error != null) return error;
    accountEmail = newEmail.trim().toLowerCase();
    notifyListeners();
    _persist();
    return null;
  }

  String? changePassword(String currentPassword, String newPassword) {
    if (!signedIn || !hasAccount) return 'Log in first.';
    if (_hashPassword(currentPassword, _passwordSalt!) != _passwordHash) return 'Current password is wrong.';
    final error = validatePassword(newPassword);
    if (error != null) return error;
    final salt = _newSalt();
    _passwordSalt = salt;
    _passwordHash = _hashPassword(newPassword, salt);
    notifyListeners();
    _persist();
    return null;
  }
}
