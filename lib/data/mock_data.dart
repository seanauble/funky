/// What's left of the old demo-seed file now that FUNKY is live: the sample
/// people, places, polls, chat, and Stories that used to live here are gone
/// on purpose — everything in the app now comes from real accounts. All
/// that's still needed is a fallback map center and a blank starting
/// profile.
library;

import 'models.dart';
import 'session.dart';

// Only used as a map/ranking center until the phone's real location comes
// in (the app itself gates on real location — see LocationGate).
const defaultLocation = LatLng(39.7052, -75.114); // Glassboro, NJ

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
      seen: const [],
      likes: const [],
    );
