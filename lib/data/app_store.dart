import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'geo.dart';
import 'mock_data.dart';
import 'models.dart';
import 'session.dart';

const _storageKey = 'funky.store.v1';

enum LocationStatus { unknown, requesting, granted, denied }

class RankedPlace {
  final Place place;
  final double distance;
  final int going;
  final int heat; // 0-3
  final Report? cover;

  RankedPlace({required this.place, required this.distance, required this.going, required this.heat, this.cover});

  String get id => place.id;
  String get name => place.name;
  PlaceKind get kind => place.kind;
  String get address => place.address;
}

class ChatRoom {
  final String id;
  final String name;
  final int heat;
  const ChatRoom(this.id, this.name, this.heat);
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

  AppStore() {
    final session = sessionKey();
    people = {for (final p in samplePeople(session)) p.id: p};
    places = sampleWithSession(session);
    polls = samplePolls(session);
    messages = sampleMessages();
    stories = sampleStories(session);
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

        if (storedSession == currentSession) {
          me = parsedMe;
          places = _dedupeById([...places, ...parsedPlaces], (p) => p.id);
          polls = _dedupeById([...polls, ...parsedPolls], (p) => p.id);
          messages = _dedupeById([...messages, ...parsedMessages], (m) => m.id);
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
        } else {
          // Stale night — carry over only what survives the reset (rule 3).
          me = Person(
            id: parsedMe.id,
            handle: parsedMe.handle,
            bio: parsedMe.bio,
            since: parsedMe.since,
            points: parsedMe.points,
            following: parsedMe.following,
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
      return RankedPlace(place: p, distance: milesBetween(here, LatLng(p.lat, p.lng)), going: going, heat: heat, cover: cover);
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

  List<ChatRoom> get roomsForChat {
    final ranked = rankedPlaces;
    return [const ChatRoom('main', 'Area chat', 0), ...ranked.map((p) => ChatRoom(p.id, p.name, p.heat))];
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

  void addStory({String? text, required String place, required bool anon}) {
    final story = Story(
      id: 'story_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      uid: 'me',
      text: text,
      place: place,
      anon: anon,
      session: sessionKey(),
      views: const [],
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
}
