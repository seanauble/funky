/// Seed data for the mock store — lifted directly from the web prototype's
/// own `FALLBACK` block (the "three sample places near Glassboro, NJ" mode
/// HANDOFF.md describes) so the native app starts from the exact same
/// sample night instead of inventing new placeholder content.
library;

import 'dart:math';
import 'models.dart';
import 'session.dart';

const defaultLocation = LatLng(39.7052, -75.114); // Glassboro, NJ

class Town {
  final String label;
  final double lat;
  final double lng;
  const Town(this.label, this.lat, this.lng);
}

const towns = [
  Town('Glassboro, NJ', 39.7052, -75.114),
  Town('Philadelphia, PA', 39.9526, -75.1652),
  Town('Atlantic City, NJ', 39.3625, -74.425),
  Town('Ocean City, NJ', 39.2776, -74.5746),
  Town('Hoboken, NJ', 40.744, -74.0324),
];

List<Place> sampleWithSession(String session) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    Place(id: 'sigchi', name: 'Sigma Chi', kind: PlaceKind.frat, lat: 39.7075, lng: -75.1235, address: '214 Mullica Hill Rd', by: 'demo', t: now, session: session),
    Place(id: 'pike', name: 'Pike', kind: PlaceKind.frat, lat: 39.7135, lng: -75.115, address: '301 Whitney Ave', by: 'demo', t: now, session: session),
    Place(id: 'downtown', name: 'Downtown', kind: PlaceKind.area, lat: 39.7045, lng: -75.1125, address: 'High St & Delsea Dr', by: 'demo', t: now, session: session),
    Place(id: 'hq', name: 'HQ Nightclub', kind: PlaceKind.club, lat: 39.362, lng: -74.413, address: 'Atlantic City, NJ', by: 'demo', t: now, session: session),
    Place(id: 'point', name: 'The Point', kind: PlaceKind.bar, lat: 39.308, lng: -74.595, address: 'Ocean City, NJ', by: 'demo', t: now, session: session),
  ];
}

List<Poll> samplePolls(String session) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    Poll(id: 'rowan-out', q: 'Going out tonight?', options: const ['Obviously', 'Maybe', 'Staying in'], lat: 39.7102, lng: -75.1196, by: 'demo', t: now, session: session),
    Poll(id: 'ac-best', q: 'Best bar tonight?', options: const ['The Point', 'HQ Nightclub', 'Somewhere else'], lat: 39.3643, lng: -74.4229, by: 'demo', t: now, session: session),
  ];
}

Person _mkDemo(String id, String handle, String bio, String move, String session) {
  final rnd = Random();
  return Person(
    id: id,
    handle: handle,
    bio: bio,
    since: 2026,
    points: 20 + rnd.nextInt(180),
    friends: const [],
    friendRequestsSent: const [],
    friendRequestsReceived: const [],
    muted: const [],
    anon: false,
    demo: true,
    session: session,
    move: move,
    votes: const {},
    reports: const {},
    seen: const [],
    likes: const [],
  );
}

List<Person> samplePeople(String session) => [
      _mkDemo('p1', 'wildcard92', 'here for the pregame', 'sigchi', session),
      _mkDemo('p2', 'shortkingjames', "rowan '27", 'downtown', session),
      _mkDemo('p3', 'beachbum', 'AC this weekend', 'point', session),
    ];

List<ChatMessage> sampleMessages() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    ChatMessage(id: 'm1', t: now - 1000 * 60 * 42, room: 'main', uid: 'p1', text: "who's actually going out tonight", anon: false),
    ChatMessage(id: 'm2', t: now - 1000 * 60 * 35, room: 'main', uid: 'p2', text: 'sig chi is giving pregame energy rn', anon: false),
    ChatMessage(id: 'm3', t: now - 1000 * 60 * 12, room: 'sigchi', uid: 'p1', text: 'line is already out the door 💀', anon: false),
  ];
}

List<Story> sampleStories(String session) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    Story(id: 's1', t: now - 1000 * 60 * 50, uid: 'p1', text: 'pregame loading', place: 'sigchi', anon: false, session: session, views: const [], likes: const ['p2']),
    Story(id: 's2', t: now - 1000 * 60 * 20, uid: 'p3', text: 'boardwalk before the bars', place: 'point', anon: false, session: session, views: const [], likes: const []),
  ];
}

Person freshMe() => Person(
      id: 'me',
      handle: 'you',
      bio: '',
      since: DateTime.now().year,
      points: 0,
      friends: const [],
      friendRequestsSent: const [],
      friendRequestsReceived: const [],
      muted: const [],
      anon: false,
      session: sessionKey(),
      move: null,
      votes: const {},
      reports: const {},
      seen: const [],
      likes: const [],
    );
