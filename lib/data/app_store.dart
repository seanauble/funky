import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'geo.dart';
import 'mock_data.dart';
import 'models.dart';
import 'session.dart';

const _storageKey = 'funky.store.v1';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

enum LocationStatus { unknown, requesting, granted, denied }

class RankedPlace {
  final Place place;
  final double distance;
  final int going;
  final int heat; // 0-3
  final int score; // raw activity score the heat bucket and map glow are built from
  // Newest report per kind for this place (cover/police/shutdown/line/
  // capacity) — see AppStore.reportsFor. Empty map means nothing reported.
  final Map<ReportKind, PlaceReport> reports;

  RankedPlace({
    required this.place,
    required this.distance,
    required this.going,
    required this.heat,
    required this.score,
    this.reports = const {},
  });

  String get id => place.id;
  String get name => place.name;
  PlaceKind get kind => place.kind;
  String get address => place.address;
  String? get coverPhotoPath => place.coverPhotoPath;
}

/// The canonical chat "room" key for a DM thread between two people — the
/// ids get sorted first so (me, p1) and (p1, me) always land on the exact
/// same room no matter who opened the thread, reusing the same
/// ChatMessage/room plumbing the area live chat already runs on.
String dmRoomId(String a, String b) {
  final ids = [a, b]..sort();
  return 'dm_${ids[0]}_${ids[1]}';
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
/// Flutter ChangeNotifier: same 2 PM reset logic (rule 2/3), same ranking
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
  // Every crowd-sourced report ever submitted tonight (cover/police/
  // shutdown/line/capacity). Nothing is ever mutated in place — a new
  // submission for the same place+kind just gets appended and supersedes
  // the old one; see reportsFor, which is the only thing that reads this
  // list directly.
  List<PlaceReport> placeReports = [];

  // Confirming a report from far away would make it trivially easy to sit
  // at home and fake community support, so a real confirm (not a demo-seed
  // one) requires being within this many miles of wherever location says
  // you are right now.
  static const double _confirmRadiusMiles = 2;

  // Separate from report verification: this is "is this venue even real",
  // confirmed by placeId -> the ids of everyone who's vouched for it. 15
  // unique confirmations (vs. 8 for a report) is what lets a venue show up
  // on the Home tab's trending carousel, story rings, and "what's the
  // move" quick-picks — see AppStore.rankedPlaces callers in home_screen.
  // The Places tab itself still lists everything, verified or not, so a
  // brand-new venue can actually be found and confirmed in the first place.
  Map<String, List<String>> placeConfirmations = {};
  static const int venueVerificationThreshold = 15;

  // FUNKY Admin — one hardcoded account (there's no real backend/roles
  // here, so this just checks the signed-in account's email against the
  // one real admin address) who can mark a venue verified outright,
  // bypassing the 15-confirmation crowd bar entirely. Everyone else's
  // "Confirm" button still only ever feeds the normal count.
  static const String _adminEmail = 'seanauble@icloud.com';
  bool get isAdmin => signedIn && accountEmail == _adminEmail;

  // Which venues a FUNKY Admin has manually verified — separate from
  // placeConfirmations (which only ever holds real crowd confirmations).
  // Deliberately not tied to tonight's session/reset: an admin shouldn't
  // have to re-verify the same bar every night.
  Set<String> adminVerifiedPlaceIds = {};

  bool isAdminVerified(String placeId) => adminVerifiedPlaceIds.contains(placeId);

  // Who a FUNKY Admin has banned — hides their Stories, live-chat messages,
  // and DM threads from everyone on this device (see the isBanned filters
  // in home_screen.dart/chat_screen.dart), and banning also severs any
  // existing friendship/pending request with them (see banUser). Never
  // tied to tonight's session, same as adminVerifiedPlaceIds — a ban
  // shouldn't quietly undo itself at the 2 PM reset.
  Set<String> bannedUserIds = {};

  bool isBanned(String personId) => bannedUserIds.contains(personId);

  /// Admin-only — removes [personId] from the social graph on this device:
  /// unfriends them both ways, clears any pending request between you, and
  /// marks them banned so their Stories/chat messages/DMs stop showing up
  /// anywhere (home_screen's story rings, the live chat, Messages). Silently
  /// does nothing for a non-admin account or for 'me', same guard pattern as
  /// setAdminVerified.
  void banUser(String personId) {
    if (!isAdmin || personId == 'me') return;
    final next = Set<String>.from(bannedUserIds)..add(personId);
    bannedUserIds = next;
    me = me.copyWith(
      friends: me.friends.where((id) => id != personId).toList(),
      friendRequestsSent: me.friendRequestsSent.where((id) => id != personId).toList(),
      friendRequestsReceived: me.friendRequestsReceived.where((id) => id != personId).toList(),
    );
    final them = people[personId];
    if (them != null) {
      people = {
        ...people,
        personId: them.copyWith(
          friends: them.friends.where((id) => id != 'me').toList(),
          friendRequestsSent: them.friendRequestsSent.where((id) => id != 'me').toList(),
          friendRequestsReceived: them.friendRequestsReceived.where((id) => id != 'me').toList(),
        ),
      };
    }
    notifyListeners();
    _persist();
  }

  /// Admin-only — lifts a ban. Doesn't restore the friendship that banning
  /// severed; that's a fresh Add Friend if either side wants it back.
  void unbanUser(String personId) {
    if (!isAdmin) return;
    final next = Set<String>.from(bannedUserIds)..remove(personId);
    bannedUserIds = next;
    notifyListeners();
    _persist();
  }

  /// Admin-only — permanently removes a place from tonight's list, along
  /// with its reports/confirmations/verification. Stories already posted
  /// there stay in whoever posted them's Memories (same as what happens
  /// when a place naturally rolls off at the 2 PM reset) — they just lose
  /// the still-live venue record they pointed at. Silently does nothing for
  /// a non-admin account.
  void deletePlace(String placeId) {
    if (!isAdmin) return;
    places = places.where((p) => p.id != placeId).toList();
    placeReports = placeReports.where((r) => r.placeId != placeId).toList();
    placeConfirmations = Map<String, List<String>>.from(placeConfirmations)..remove(placeId);
    adminVerifiedPlaceIds = Set<String>.from(adminVerifiedPlaceIds)..remove(placeId);
    notifyListeners();
    _persist();
  }

  /// Admin-only — permanently deletes one chat message, area-chat or a DM.
  /// Silently does nothing for a non-admin account.
  void deleteMessage(String messageId) {
    if (!isAdmin) return;
    messages = messages.where((m) => m.id != messageId).toList();
    notifyListeners();
    _persist();
  }

  /// Admin-only toggle — silently does nothing for a non-admin account, so
  /// a UI bug can never let a regular user flip this (the UI itself also
  /// only ever shows the control to store.isAdmin in the first place).
  void setAdminVerified(String placeId, bool verified) {
    if (!isAdmin) return;
    final next = Set<String>.from(adminVerifiedPlaceIds);
    if (verified) {
      next.add(placeId);
    } else {
      next.remove(placeId);
    }
    adminVerifiedPlaceIds = next;
    notifyListeners();
    _persist();
  }

  bool isPlaceVerified(String placeId) =>
      isAdminVerified(placeId) || (placeConfirmations[placeId]?.length ?? 0) >= venueVerificationThreshold;

  int venueConfirmationCount(String placeId) => placeConfirmations[placeId]?.length ?? 0;

  /// The venue-status line shown wherever a place is listed without the
  /// room for place_detail_screen's full two-line card — three distinct
  /// states, so "not verified yet" never reads the same as "a FUNKY Admin
  /// manually verified this": admin override, cleared the crowd's
  /// confirmation bar on its own, or still short of it (and by how much).
  String venueStatusLabel(String placeId) {
    if (isAdminVerified(placeId)) return 'FUNKY Verified';
    final count = venueConfirmationCount(placeId);
    if (count >= venueVerificationThreshold) return 'Verified · $count confirmations';
    return 'Not admin verified · $count/$venueVerificationThreshold confirmations';
  }

  bool hasConfirmedPlace(String placeId) => placeConfirmations[placeId]?.contains('me') ?? false;

  /// Vouches that [placeId] is a real, currently-active venue. Same
  /// one-confirm-per-account rule as report confirmations.
  String? confirmPlace(String placeId) {
    final current = placeConfirmations[placeId] ?? const [];
    if (current.contains('me')) return null;
    placeConfirmations = {...placeConfirmations, placeId: [...current, 'me']};
    notifyListeners();
    _persist();
    return null;
  }

  // --- FUNKY Points ----------------------------------------------------
  // The big idea: the biggest rewards come from contributing information
  // that other people actually confirm, not from doing infinitely-repeatable
  // things (chatting, liking, opening the app). Every call site below is
  // the one place that action's reward is decided, so the whole table
  // lives in one spot:
  //   first night using FUNKY           +25  (load(), brand-new install)
  //   mark yourself "going"             +3   (setMove, first pick of the night)
  //   post a Story at a venue           +5   (addStory, when it's tied to a place)
  //   submit a cover/line/capacity report +3 (submitReport)
  //   submit a police/shutdown report   +5   (submitReport — higher-stakes info)
  //   confirm someone else's report     +2   (confirmReport)
  //   your report becomes Verified (8+) +15  (confirmReport, cover/line/capacity)
  //   your shutdown/police becomes Verified +20 (confirmReport)
  //   add a missing venue               +10  (addPlace)
  //   3/7/30-night activity streak      +10/+30/+100 (_recordNightActivity)
  // Inviting a friend who joins isn't wired up yet — there's no real invite
  // link/backend for FUNKY to know an invite actually converted.
  void _award(int n) {
    me = me.copyWith(points: me.points + n);
  }

  /// Call from any action that should count as "being out tonight" —
  /// tracks which nights (by session key) you've done at least one
  /// qualifying thing, which drives both the Night Owl badge and the
  /// streak bonus. Safe to call more than once per night (a no-op after
  /// the first time).
  void _recordNightActivity() {
    final today = sessionKey();
    if (me.activeNights.contains(today)) return;
    int newStreak = 1;
    if (me.activeNights.isNotEmpty) {
      try {
        final lastDay = DateTime.parse(me.activeNights.last);
        final todayDate = DateTime.parse(today);
        if (todayDate.difference(lastDay).inDays == 1) newStreak = me.streak + 1;
      } catch (_) {
        // Malformed stored date — just restart the streak rather than crash.
      }
    }
    me = me.copyWith(activeNights: [...me.activeNights, today], streak: newStreak);
    if (newStreak == 3) _award(10);
    if (newStreak == 7) _award(30);
    if (newStreak == 30) _award(100);
  }

  /// A simple, ever-increasing level number from points (every 250 points
  /// is another level) — shown alongside the title so progress feels
  /// continuous between title tiers.
  int get level => levelFor(me.points);

  /// The title tier you've chosen to show (see [setDisplayedTitle]) if
  /// it's still one you've actually reached, otherwise the highest
  /// points-title tier you've reached (500 Reliable Source … 10000 KING
  /// FUNKY), or null below 500. Purely cosmetic — separate from
  /// report/venue verification.
  LevelTitle? get myLevelTitle {
    final chosen = me.displayedTitleThreshold;
    if (chosen != null) {
      for (final t in levelTitles) {
        if (t.threshold == chosen && me.points >= t.threshold) return t;
      }
    }
    return levelTitleFor(me.points);
  }

  /// Every title tier reached so far, highest first — what the "pick which
  /// badge to show" screen offers (see setDisplayedTitle).
  List<LevelTitle> get myUnlockedTitles => levelTitlesFor(me.points);

  /// Choose which earned title tier shows beside your name instead of
  /// always defaulting to the highest one — pass null to go back to
  /// "always show my highest". Silently ignored if you haven't actually
  /// reached that tier (can't be unlocked through this).
  void setDisplayedTitle(LevelTitle? title) {
    if (title == null) {
      me = me.copyWith(clearDisplayedTitleThreshold: true);
    } else if (me.points >= title.threshold) {
      me = me.copyWith(displayedTitleThreshold: title.threshold);
    }
    notifyListeners();
    _persist();
  }

  /// Flip any of the point-unlocked cosmetic name styles on or off — bold
  /// at 500, italic at 1000, underline at 2000, a checkmark badge at 5000
  /// (see canUseBoldName etc in models.dart). Every unlocked style you've
  /// turned on applies at once; turning one on that isn't unlocked yet is
  /// a no-op. Only null arguments are left unchanged.
  void setNameStyle({bool? bold, bool? italic, bool? underline, bool? checkbox}) {
    me = me.copyWith(
      nameBold: bold == null ? null : (bold && canUseBoldName(me.points)),
      nameItalic: italic == null ? null : (italic && canUseItalicName(me.points)),
      nameUnderline: underline == null ? null : (underline && canUseUnderlineName(me.points)),
      nameCheckbox: checkbox == null ? null : (checkbox && canUseCheckName(me.points)),
    );
    notifyListeners();
    _persist();
  }

  /// Earned by actually contributing and getting confirmed — see each
  /// threshold for exactly what it takes. A user can earn all of these;
  /// picking 1-3 to display is a future profile-customization step.
  List<FunkyBadge> get myBadges {
    final badges = <FunkyBadge>[];
    if (me.activeNights.length >= 10) badges.add(const FunkyBadge('🔥', 'Night Owl'));
    if (myStories.length >= 50) badges.add(const FunkyBadge('📸', 'Storyteller'));
    final verifiedReports = placeReports.where((r) => r.reporterId == 'me' && r.verified).length;
    if (verifiedReports >= 25) badges.add(const FunkyBadge('✓', 'Reliable Source'));
    if (me.placesVisited.length >= 20) badges.add(const FunkyBadge('🗺️', 'Explorer'));
    return badges;
  }

  /// The blue-check "this person's reports are worth trusting more"
  /// signal — still doesn't skip the normal 8-confirmation report
  /// verification, it just colors how much weight people give an
  /// unverified report from this account.
  bool get isVerifiedUser => me.points >= 1000 && myStories.length >= 10;

  LatLng? location;
  LocationStatus locationStatus = LocationStatus.unknown;

  // Account — browsing FUNKY is always anonymous and free; you only need
  // one of these to post a Story/poll/place or send a message (see
  // requireAccountThen in lib/screens/account_screen.dart, which is what
  // actually enforces that gate from the UI). A REAL Supabase Auth account
  // now (see signUp/signIn/etc. below) — accountEmail/signedIn/
  // supabaseUserId always mirror Supabase's own current session (re-derived
  // fresh in load(), not trusted from local storage), not a locally-faked
  // password check like before. supabaseUserId is this device's bridge to
  // the real backend's `profiles`/`friendships`/`stories`/`messages` tables
  // — everything else in AppStore still runs on the local 'me' sentinel id
  // for now; wiring those up to the real tables is the next phase.
  String? accountEmail;
  String? supabaseUserId;
  bool signedIn = false;

  // Anti-spam: the server-free equivalent of a rate limit. Covers chat
  // messages (sendMessage) — see also the 15-day cooldown on setHandle just
  // below, which reuses the same "store the last-change timestamp, compare
  // against now" pattern.
  int? _lastMessageAt;
  static const int _messageCooldownMs = 3000;

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

    // Demo seed so the reports UI isn't empty on a fresh install — one
    // report that's already over the verification line and one that's
    // still building confirmations, so both states are visible immediately.
    placeReports = [
      PlaceReport(
        id: 'report_demo1',
        placeId: 'sigchi',
        kind: ReportKind.cover,
        detail: '\$10',
        t: DateTime.now().millisecondsSinceEpoch,
        reporterId: 'p1',
        confirmedBy: const ['p1', 'p2', 'p3', 'demo4', 'demo5', 'demo6', 'demo7', 'demo8'],
      ),
      PlaceReport(
        id: 'report_demo2',
        placeId: 'point',
        kind: ReportKind.line,
        detail: '20 min',
        t: DateTime.now().millisecondsSinceEpoch,
        reporterId: 'p3',
        confirmedBy: const ['p3', 'p1'],
      ),
    ];

    // Demo seed so the sample venues clear the 15-confirmation bar on a
    // fresh install — otherwise Home's "verified venues only" surfaces
    // (trending carousel, story rings, what's-the-move picks) would be
    // empty until real people confirmed them, which is a bad first run.
    placeConfirmations = {
      for (final p in places)
        p.id: List.generate(venueVerificationThreshold, (i) => 'demo_confirm_${p.id}_$i'),
    };
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
        final parsedReports =
            ((parsed['placeReports'] as List?) ?? const []).map((e) => PlaceReport.fromJson(e as Map<String, dynamic>)).toList();
        // Which venues 'me' has personally vouched for — never tied to
        // tonight's session, re-applied on top of the fresh demo seed below
        // either way (a real confirm should never be lost on reload).
        final myVenueConfirmations = ((parsed['myVenueConfirmations'] as List?) ?? const []).map((e) => e as String).toSet();
        for (final placeId in myVenueConfirmations) {
          final current = placeConfirmations[placeId] ?? const [];
          if (!current.contains('me')) {
            placeConfirmations = {...placeConfirmations, placeId: [...current, 'me']};
          }
        }

        // Also never tied to tonight's session — a FUNKY Admin verification
        // should survive the 2 PM reset the same way the account itself does.
        adminVerifiedPlaceIds = ((parsed['adminVerifiedPlaceIds'] as List?) ?? const []).map((e) => e as String).toSet();

        // Same reasoning — a ban shouldn't quietly lift itself at 2 PM.
        bannedUserIds = ((parsed['bannedUserIds'] as List?) ?? const []).map((e) => e as String).toSet();

        if (storedSession == currentSession) {
          me = parsedMe;
          places = _dedupeById([...places, ...parsedPlaces], (p) => p.id);
          polls = _dedupeById([...polls, ...parsedPolls], (p) => p.id);
          messages = _dedupeById([...messages, ...parsedMessages], (m) => m.id);
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
          placeReports = _dedupeById([...placeReports, ...parsedReports], (r) => r.id);
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
            seen: const [],
            likes: const [],
            // Cumulative points history — never tied to tonight's session,
            // same as points itself just above.
            activeNights: parsedMe.activeNights,
            streak: parsedMe.streak,
            placesVisited: parsedMe.placesVisited,
            photoPath: parsedMe.photoPath,
            lastHandleChangeAt: parsedMe.lastHandleChangeAt,
          );
          // Your own Stories are permanent (Memories), even though the
          // *place* records and everyone else's tonight-only Stories get
          // wiped at reset — this used to just drop `parsedStories`
          // entirely, which is why Memories kept losing photos/videos every
          // night. _persist() only ever writes 'me'-authored stories here,
          // so this merge is always just your own history.
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
          justReset = true;
        }
      } else {
        // Nothing saved yet — this is a brand-new install, worth the
        // "First night using FUNKY" bonus (see the points comment on
        // _award below).
        _award(25);
      }
    } catch (_) {
      // Corrupt or missing storage — just start fresh, same as a new install.
    } finally {
      // Real sign-in state now comes from Supabase's own session, not a
      // locally-stored flag — supabase_flutter persists and auto-refreshes
      // that session on its own, so this just mirrors whatever it already
      // restored rather than trusting (possibly stale) local JSON.
      final session = Supabase.instance.client.auth.currentSession;
      signedIn = session != null;
      accountEmail = session?.user.email;
      supabaseUserId = session?.user.id;
      // Age out old Memories before anyone ever sees them — otherwise the
      // very first frame could flash a Memory that's about to disappear.
      _purgeExpiredMemories();
      loaded = true;
      notifyListeners();
      // Flush the purge immediately so a Memory that expired while the app
      // was closed doesn't get silently re-merged back in from storage on
      // the next launch (load() above always merges whatever's still on
      // disk; only _persist() ever rewrites it).
      _persist();
      // A session already on this device (you never signed out last time)
      // — pick the real backend sync back up the same as a fresh signIn
      // would, so Stories/DMs start flowing in without waiting for you to
      // touch the account screen.
      if (signedIn) _startRemoteSync();
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
        'placeReports': placeReports.where((r) => r.reporterId == 'me').map((r) => r.toJson()).toList(),
        'myVenueConfirmations': placeConfirmations.entries.where((e) => e.value.contains('me')).map((e) => e.key).toList(),
        // accountEmail/signedIn/supabaseUserId are no longer written here —
        // they're derived fresh from Supabase's own session on every load()
        // instead (see there), so there's nothing real to persist locally
        // for them anymore.
        'adminVerifiedPlaceIds': adminVerifiedPlaceIds.toList(),
        'bannedUserIds': bannedUserIds.toList(),
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

  List<RankedPlace> get rankedPlaces => rankedPlacesFrom(location ?? defaultLocation);

  /// [rankedPlaces] filtered to venues that have cleared the 15-confirmation
  /// bar (see placeConfirmations) — what Home's trending carousel, story
  /// rings, and "what's the move" quick-picks show, so an unverified venue
  /// can't dominate the app's main surfaces. The Places tab deliberately
  /// uses the unfiltered [rankedPlaces] instead, since that's where a new
  /// venue has to be found and confirmed in the first place.
  List<RankedPlace> get verifiedRankedPlaces => rankedPlaces.where((p) => isPlaceVerified(p.id)).toList();

  /// The newest report per [ReportKind] for a place — a fresh submission
  /// always supersedes the previous one for that same kind (and starts its
  /// own confirmation count from scratch), so this is the only place that
  /// should ever read [placeReports] directly.
  Map<ReportKind, PlaceReport> reportsFor(String placeId) {
    final mine = placeReports.where((r) => r.placeId == placeId).toList()..sort((a, b) => a.t.compareTo(b.t));
    final out = <ReportKind, PlaceReport>{};
    for (final r in mine) {
      out[r.kind] = r; // later (newer) entries overwrite earlier ones
    }
    return out;
  }

  /// Same ranking as [rankedPlaces] (activity first, then "going", then
  /// distance), but relative to an arbitrary [center] instead of your real
  /// location — what the Places map's "Search this area" uses to re-rank
  /// and re-filter around wherever you've panned to, without touching what
  /// "near you" means anywhere else in the app.
  List<RankedPlace> rankedPlacesFrom(LatLng center) {
    final allPeople = {...people, 'me': me};
    final result = places.where((p) => near(center, LatLng(p.lat, p.lng))).map((p) {
      final going = allPeople.values.where((person) => person.move == p.id).length;
      final roomMsgCount = messages.where((m) => m.room == p.id).length;
      final storyCount = stories.where((s) => s.place == p.id).length;
      final score = going * 3 + roomMsgCount + storyCount * 2;
      final heat = score >= 12 ? 3 : (score >= 5 ? 2 : (score >= 1 ? 1 : 0));
      return RankedPlace(
        place: p,
        distance: milesBetween(center, LatLng(p.lat, p.lng)),
        going: going,
        heat: heat,
        score: score,
        reports: reportsFor(p.id),
      );
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

  /// The newest Story at [placeId] that actually has a photo or video —
  /// what a place's thumbnail/banner switches to showing once something's
  /// been posted there, instead of just the flat colored-letter
  /// placeholder (Place Detail's banner, Home's trending cards, the
  /// Places list all read this). Null when nothing with media has gone up
  /// there yet.
  Story? latestMediaStoryFor(String placeId) {
    Story? latest;
    for (final s in stories) {
      if (s.place != placeId) continue;
      if (s.videoPath == null && s.imagePath == null) continue;
      if (latest == null || s.t > latest.t) latest = s;
    }
    return latest;
  }

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

  /// What the Story viewer actually shows for a tap on someone's ring —
  /// everyone can see what you post tonight (that's the whole point of a
  /// ring), but your older Stories are "memories," and memories are
  /// friends-only, same gate as the profile page (canSeeStoriesOf). A
  /// non-friend who keeps tapping through your ring stops at the edge of
  /// tonight instead of being able to page back through your whole archive.
  List<Story> visibleStoriesByUser(String uid) {
    final theirs = storiesByUser(uid);
    if (canSeeStoriesOf(uid)) return theirs;
    final today = sessionKey();
    return theirs.where((s) => s.session == today).toList();
  }

  /// Everyone 'me' is actually (mutually) friends with right now, resolved
  /// to full Person records so the UI can show their real @handle — what
  /// the new "Friends" section on FriendRequestsScreen lists, separate from
  /// the incoming/outgoing pending requests below.
  List<Person> get myFriends => me.friends.map(personById).whereType<Person>().toList();

  List<Person> get incomingFriendRequests =>
      me.friendRequestsReceived.map(personById).whereType<Person>().toList();

  List<Person> get outgoingFriendRequests =>
      me.friendRequestsSent.map(personById).whereType<Person>().toList();

  int get pendingFriendRequestCount => me.friendRequestsReceived.length;

  /// Looks up people by @handle for the magnifying-glass search on the
  /// Friends screen — so you can add someone by username directly instead
  /// of only being able to Add Friend from a Story/DM/chat you already saw
  /// them in. Always checks everyone already known on this device first
  /// (demo accounts, friends, anyone already synced in from a Story or DM)
  /// so search still works offline/signed-out; when signed in, this also
  /// queries the real `profiles` table for a case-insensitive partial match
  /// and merges any new matches into [people] (via _personFromProfileRow,
  /// same as _ensurePeopleFor) so their avatar/profile page have something
  /// real to show. Falls back to just the local matches if the remote
  /// lookup fails (offline, etc.) rather than showing an error. Banned
  /// users never show up here, same as everywhere else they're hidden.
  Future<List<Person>> searchPeopleByHandle(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final localMatches = people.values.where((p) => p.handle.toLowerCase().contains(q) && !isBanned(p.id)).toList();
    if (!signedIn || supabaseUserId == null) return localMatches;
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select()
          .ilike('handle', '%$q%')
          .neq('id', supabaseUserId!)
          .limit(25);
      final updated = Map<String, Person>.from(people);
      final matchedIds = <String>{};
      for (final row in rows) {
        final id = row['id'] as String;
        matchedIds.add(id);
        if (isBanned(id)) continue;
        // Same rule as _ensurePeopleFor — never clobber a Person record
        // already in [people] (e.g. an existing friend's local state), only
        // fill in ones this device hasn't seen before.
        if (!people.containsKey(id)) updated[id] = _personFromProfileRow(row);
        _remotePersonIds.add(id);
      }
      people = updated;
      notifyListeners();
      // Re-resolve through `people` (rather than the raw rows) so a match
      // that's already a friend/pending request still shows its real local
      // state, and de-dupe against anyone already caught by localMatches.
      final ids = <String>{...localMatches.map((p) => p.id), ...matchedIds};
      return ids.where((id) => !isBanned(id)).map(personById).whereType<Person>().toList();
    } catch (_) {
      // Offline or a transient error — still show whatever matched locally.
      return localMatches;
    }
  }

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

  // How often you're allowed to actually change your @handle — just
  // picking a handle for the first time (lastHandleChangeAt still null)
  // isn't rate-limited, only changing an existing one is.
  static const int _handleChangeCooldownMs = 15 * 24 * 60 * 60 * 1000;

  /// Returns null on success, or a user-facing error (still inside the
  /// 15-day cooldown) if the change didn't go through.
  String? setHandle(String handle) {
    final trimmed = handle.trim();
    if (trimmed.isEmpty) return 'Enter a username.';
    if (trimmed == me.handle) return null; // unchanged — no-op, no cooldown hit
    final last = me.lastHandleChangeAt;
    if (last != null) {
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsedMs < _handleChangeCooldownMs) {
        final daysLeft = ((_handleChangeCooldownMs - elapsedMs) / (24 * 60 * 60 * 1000)).ceil();
        return "You can change your username again in $daysLeft day${daysLeft == 1 ? '' : 's'}.";
      }
    }
    me = me.copyWith(handle: trimmed, lastHandleChangeAt: DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
    _persist();
    // Best-effort — other real accounts read your @handle from the
    // `profiles` table (see _personFromProfileRow), not from this device's
    // local copy, so a real account's handle needs to actually reach the
    // server. profiles.handle is UNIQUE there; a collision just fails this
    // silently and your local handle stays changed anyway — a known gap
    // (not surfaced as an error here) rather than reworking this into an
    // async, pre-checked flow.
    if (signedIn && supabaseUserId != null) {
      _fireAndForgetUpdate('profiles', {'handle': trimmed}, supabaseUserId!);
    }
    return null;
  }

  /// Sets a profile photo captured with the in-app camera — FUNKY never
  /// uses a gallery/image picker, same rule as Stories (see
  /// CameraCaptureScreen).
  void setProfilePhoto(String path) {
    me = me.copyWith(photoPath: path);
    notifyListeners();
    _persist();
  }

  void setBio(String bio) {
    me = me.copyWith(bio: bio);
    notifyListeners();
    _persist();
    if (signedIn && supabaseUserId != null) {
      _fireAndForgetUpdate('profiles', {'bio': bio}, supabaseUserId!);
    }
  }

  void setAnon(bool value) {
    me = me.copyWith(anon: value);
    notifyListeners();
    _persist();
  }

  void setMove(String placeIdOrIn) {
    final isFirstPickTonight = me.move == null;
    var visited = me.placesVisited;
    if (placeIdOrIn != 'in' && !visited.contains(placeIdOrIn)) {
      visited = [...visited, placeIdOrIn];
    }
    me = me.copyWith(move: placeIdOrIn, placesVisited: visited);
    if (isFirstPickTonight) _award(3); // "vote where you're going"
    _recordNightActivity();
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

  /// One place add per day (same 2 PM rolling reset as everything else) —
  /// keeps the map from getting spammed with duplicate/fake venues. true
  /// means the slot is still open tonight.
  bool get canAddPlaceToday => !places.any((p) => p.by == 'me' && p.session == sessionKey());

  /// Same one-per-day rule as places, for polls.
  bool get canAddPollToday => !polls.any((p) => p.by == 'me' && p.session == sessionKey());

  // Lowercased, letters/digits-only — so "Sigma Chi", "sigma-chi!", and
  // "Sigma  Chi" all collapse to the same key before comparing names.
  String _normalizedPlaceName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// The existing place within the 25-mile radius (same radius
  /// [rankedPlacesFrom] uses — "nearby" always means the same thing) whose
  /// name looks like a duplicate of [name], or null if there isn't one.
  /// Lets the Add Place form warn before you even try to submit, and
  /// backstops [addPlace] itself in case something slips past that check.
  Place? similarNearbyPlace(String name) {
    final target = _normalizedPlaceName(name);
    if (target.isEmpty) return null;
    final here = location ?? defaultLocation;
    for (final p in places) {
      if (!near(here, LatLng(p.lat, p.lng))) continue;
      final existing = _normalizedPlaceName(p.name);
      if (existing.isEmpty) continue;
      if (existing == target || existing.contains(target) || target.contains(existing)) return p;
    }
    return null;
  }

  /// Returns the new place, or null if you've already added one today (see
  /// [canAddPlaceToday]) or a nearby place with a similar name already
  /// exists (see [similarNearbyPlace]). Callers should check both first so
  /// they can disable the "Add place" button instead of only finding out
  /// after.
  Place? addPlace(String name, PlaceKind kind, String address, {String? coverPhotoPath}) {
    if (!canAddPlaceToday) return null;
    if (similarNearbyPlace(name) != null) return null;
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
      coverPhotoPath: coverPhotoPath,
    );
    places = [...places, place];
    // Same demo-boost the 5 built-in venues got in the constructor — without
    // this, a venue you add starts at 0 confirmations and can never clear
    // the 15-confirmation bar, so it would never show up on Home's
    // verified-only surfaces (trending, story rings, what's-the-move) no
    // matter how much Story activity happened there.
    placeConfirmations = {
      ...placeConfirmations,
      place.id: [...List.generate(venueVerificationThreshold - 1, (i) => 'demo_confirm_${place.id}_$i'), 'me'],
    };
    _award(10); // "add a missing venue"
    _recordNightActivity();
    notifyListeners();
    _persist();
    return place;
  }

  /// Returns the new poll, or null if you've already added one today —
  /// see [canAddPollToday]. Callers should check that first so they can
  /// disable the "Post poll" button instead of only finding out after.
  Poll? addPoll(String q, List<String> options) {
    if (!canAddPollToday) return null;
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

  /// Returns null on success, or a user-facing error if you're still inside
  /// the cooldown (basic anti-spam — nothing fancier than "wait a moment").
  String? sendMessage(String room, String text, bool anon) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    final message = ChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      room: room,
      uid: 'me',
      text: text,
      anon: anon,
    );
    messages = [...messages, message];
    _lastMessageAt = now;
    notifyListeners();
    _persist();
    return null;
  }

  /// A DM to one specific person instead of the shared area chat — same
  /// message plumbing (ChatMessage/sendMessage) for a local/demo person,
  /// just addressed to a per-pair room (see dmRoomId) instead of 'main'.
  /// Always sent under your real handle; ghost mode is an area-chat-only
  /// thing. For a REAL account (one whose profile we've actually fetched
  /// from the backend — see _remotePersonIds/_ensurePeopleFor), this
  /// instead writes straight to Supabase's `messages` table and waits for
  /// the real row back, so it shows up under the id the realtime
  /// subscription will also see — see _onRemoteMessageInsert's no-op-if-
  /// already-present check, which is what stops that from double-posting.
  /// Returns null on success, same contract as sendMessage.
  Future<String?> sendDirectMessage(String toPersonId, String text) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    if (signedIn && supabaseUserId != null && _remotePersonIds.contains(toPersonId)) {
      try {
        final rows = await Supabase.instance.client.from('messages').insert({
          'sender_id': supabaseUserId,
          'recipient_id': toPersonId,
          'text': text,
        }).select();
        final msg = _messageFromRow(rows.first);
        if (msg != null) {
          _remoteMessageIds.add(msg.id);
          messages = [...messages, msg];
          _lastMessageAt = now;
          notifyListeners();
          _persist();
          return null;
        }
      } catch (_) {
        // Falls through to the local-only send below so the message still
        // shows up on this device even if the real send failed (offline,
        // etc.) — it just won't reach the other person's phone until a
        // retry succeeds.
      }
    }
    return sendMessage(dmRoomId('me', toPersonId), text, false);
  }

  /// Everyone 'me' has a DM thread with, most-recently-active first — what
  /// the Messages segment of Chat lists. Real accounts' threads (synced via
  /// the backend's `messages` table) and local/demo ones are both just
  /// entries in [messages] by this point, so this reads the same either way
  /// — see sendDirectMessage/_onRemoteMessageInsert for how a real one gets in.
  List<Person> get dmConversations {
    final lastByPartner = <String, int>{};
    for (final m in messages) {
      if (!m.room.startsWith('dm_')) continue;
      final ids = m.room.substring(3).split('_');
      if (ids.length != 2) continue;
      final other = ids[0] == 'me' ? ids[1] : (ids[1] == 'me' ? ids[0] : null);
      if (other == null) continue;
      final existing = lastByPartner[other];
      if (existing == null || m.t > existing) lastByPartner[other] = m.t;
    }
    final partners = lastByPartner.keys.map(personById).whereType<Person>().where((p) => !isBanned(p.id)).toList();
    partners.sort((a, b) => lastByPartner[b.id]!.compareTo(lastByPartner[a.id]!));
    return partners;
  }

  /// Posts a new Story. When signed in, this also uploads any photo/video
  /// to Supabase Storage and inserts the real row first (see the real
  /// backend sync section below) so other real accounts can actually see
  /// it — the local Story this device displays then carries the server's
  /// own id, with its own local file kept for instant local playback (no
  /// need to re-download your own just-captured upload). If that upload or
  /// insert fails (offline, etc.) this still posts locally under a local id
  /// so posting never silently fails on this device — it just won't reach
  /// anyone else's phone until a retry succeeds.
  Future<void> addStory({String? text, String? imagePath, String? videoPath, required String place, required bool anon}) async {
    // A snapshot of the place's name right now — Places are tonight-only
    // and get wiped at 2 PM, but a Story's entry in Memories is permanent,
    // so this is what lets an old Memory still say "Posted at Sigma Chi"
    // long after that place record is gone. Null for the general feed.
    String? placeName;
    if (place != 'main') {
      for (final p in places) {
        if (p.id == place) {
          placeName = p.name;
          break;
        }
      }
    }

    String? remoteId;
    final uid = supabaseUserId;
    if (signedIn && uid != null) {
      try {
        final client = Supabase.instance.client;
        String? mediaPath;
        final localMediaFile = imagePath ?? videoPath;
        if (localMediaFile != null) {
          final ext = localMediaFile.contains('.') ? localMediaFile.split('.').last : 'dat';
          // Storage RLS checks (storage.foldername(name))[1] = auth.uid(),
          // so the upload path's first folder segment must be your own id —
          // see supabase/schema.sql.
          mediaPath = '$uid/${DateTime.now().millisecondsSinceEpoch}.$ext';
          final bytes = await File(localMediaFile).readAsBytes();
          await client.storage.from('stories').uploadBinary(mediaPath, bytes, fileOptions: const FileOptions(upsert: false));
        }
        final rows = await client.from('stories').insert({
          'uid': uid,
          'text': text,
          'place_id': place == 'main' ? null : place,
          'place_name': placeName,
          'anon': anon,
          'media_path': mediaPath,
          'is_video': videoPath != null,
        }).select();
        remoteId = rows.first['id'] as String;
      } catch (_) {
        // Falls through to the local-only post below.
      }
    }

    final story = Story(
      id: remoteId ?? 'story_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      uid: 'me',
      text: text,
      imagePath: imagePath,
      videoPath: videoPath,
      place: place,
      placeName: placeName,
      anon: anon,
      session: sessionKey(),
      // A real post starts at its real (zero) view count — the demo-seed
      // "a couple people already saw it" boost below is only for the
      // local-only fallback, so a brand-new real account's feed doesn't
      // look broken before anyone else has actually seen it.
      views: remoteId != null ? const [] : (people.keys.toList()..shuffle()).take(2).toList(),
      likes: const [],
    );
    if (remoteId != null) _remoteStoryIds.add(remoteId);
    stories = [...stories, story];
    if (place != 'main') _award(5); // "post a Story at a venue"
    _recordNightActivity();
    notifyListeners();
    _persist();
  }

  /// Toggles 'me' reacting to a chat message with [emoji] — double-tapping a
  /// bubble sends a quick ❤️, or picking from the hold-to-react strip sends
  /// whichever emoji was tapped. Tapping the same emoji again (either way)
  /// removes it; reacting with a different emoji replaces your previous one
  /// on that message instead of stacking multiple reactions from the same
  /// person, same as iMessage tapbacks.
  void toggleReaction(String messageId, String emoji) {
    final i = messages.indexWhere((m) => m.id == messageId);
    if (i == -1) return;
    final current = messages[i].reactions;
    final next = <String, List<String>>{};
    final alreadyThisEmoji = (current[emoji] ?? const []).contains('me');
    for (final entry in current.entries) {
      final uids = entry.value.where((u) => u != 'me').toList();
      if (uids.isNotEmpty) next[entry.key] = uids;
    }
    if (!alreadyThisEmoji) {
      next[emoji] = [...(next[emoji] ?? const []), 'me'];
    }
    messages = [...messages]..[i] = messages[i].copyWith(reactions: next);
    notifyListeners();
    _persist();
  }

  /// Deletes one of your own Stories — from a memory card on your profile,
  /// or the swipe-up "delete" option in the Story viewer on your own
  /// story. Only ever removes a Story that's actually yours; a stray call
  /// with someone else's id (or a stale/duplicate tap) just no-ops rather
  /// than touching anyone else's post.
  void deleteStory(String storyId) {
    final i = stories.indexWhere((s) => s.id == storyId && s.uid == 'me');
    if (i == -1) return;
    stories = [...stories]..removeAt(i);
    notifyListeners();
    _persist();
    if (signedIn && supabaseUserId != null && _remoteStoryIds.contains(storyId)) {
      _remoteStoryIds.remove(storyId);
      unawaited(() async {
        try {
          await Supabase.instance.client.from('stories').delete().eq('id', storyId);
        } catch (_) {
          // Best-effort — it's already gone from this device either way.
        }
      }());
    }
  }

  /// Pins a Memory so it never auto-deletes — the bookmark action on a
  /// Memory card, or "Save to Timeline" in the own-story swipe-up sheet.
  void saveToTimeline(String storyId) {
    final i = stories.indexWhere((s) => s.id == storyId && s.uid == 'me');
    if (i == -1) return;
    final updated = [...stories];
    updated[i] = updated[i].copyWith(savedToTimeline: true);
    stories = updated;
    notifyListeners();
    _persist();
  }

  /// Un-pins a Memory, putting it back on the normal memoryRetentionDays
  /// countdown (see _purgeExpiredMemories).
  void removeFromTimeline(String storyId) {
    final i = stories.indexWhere((s) => s.id == storyId && s.uid == 'me');
    if (i == -1) return;
    final updated = [...stories];
    updated[i] = updated[i].copyWith(savedToTimeline: false);
    stories = updated;
    notifyListeners();
    _persist();
  }

  /// Drops your own Stories once they're older than memoryRetentionDays,
  /// unless they've been explicitly saved to your Timeline. Run once per
  /// load() — everyone else's Stories are already handled by the normal
  /// 2 PM session reset elsewhere, so this only ever looks at 'me'.
  void _purgeExpiredMemories() {
    final cutoff = DateTime.now().subtract(const Duration(days: memoryRetentionDays)).millisecondsSinceEpoch;
    stories = stories.where((s) => s.uid != 'me' || s.savedToTimeline || s.t >= cutoff).toList();
  }

  void likeStory(String id) {
    final i = stories.indexWhere((s) => s.id == id);
    if (i == -1 || stories[i].likes.contains('me')) return;
    stories = [...stories]..[i] = stories[i].copyWith(likes: [...stories[i].likes, 'me']);
    notifyListeners();
    _persist();
    if (signedIn && supabaseUserId != null && _remoteStoryIds.contains(id)) {
      _fireAndForgetInsert('story_likes', {'story_id': id, 'liker_id': supabaseUserId});
    }
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
    if (signedIn && supabaseUserId != null && _remoteStoryIds.contains(storyId)) {
      _fireAndForgetInsert('story_views', {'story_id': storyId, 'viewer_id': supabaseUserId});
    }
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

  /// Submits a brand-new report for a place — cover charge, police,
  /// shutdown, line, or capacity. This always starts a fresh
  /// [PlaceReport] (it supersedes whatever was there before for that
  /// kind — see reportsFor) rather than editing one in place, because a
  /// verified report shouldn't be able to drift stale: new info has to
  /// re-earn its own 8 confirmations. The reporter counts as the first
  /// confirmation, per the spec.
  PlaceReport submitReport(String placeId, ReportKind kind, {String? detail}) {
    final report = PlaceReport(
      id: 'report_${DateTime.now().millisecondsSinceEpoch}',
      placeId: placeId,
      kind: kind,
      detail: detail,
      t: DateTime.now().millisecondsSinceEpoch,
      reporterId: 'me',
      confirmedBy: const ['me'],
    );
    placeReports = [...placeReports, report];
    // Police/shutdown reports are higher-stakes than a cover charge or a
    // line length, so submitting one is worth a bit more.
    _award(kind == ReportKind.police || kind == ReportKind.shutdown ? 5 : 3);
    _recordNightActivity();
    notifyListeners();
    _persist();
    return report;
  }

  /// Confirms an existing report as 'me'. Returns null on success, or a
  /// user-facing error string if the confirm didn't go through (already
  /// confirmed, or too far from the place to confirm it — see
  /// _confirmRadiusMiles). A user can only confirm a given report once.
  String? confirmReport(String reportId) {
    final i = placeReports.indexWhere((r) => r.id == reportId);
    if (i == -1) return "Couldn't find that report.";
    final report = placeReports[i];
    if (report.confirmedBy.contains('me')) return null; // already confirmed — no-op

    Place? place;
    for (final p in places) {
      if (p.id == report.placeId) {
        place = p;
        break;
      }
    }
    if (location != null && place != null) {
      final distance = milesBetween(location!, LatLng(place.lat, place.lng));
      if (distance > _confirmRadiusMiles) {
        return "You're too far from this spot to confirm it — get closer and try again.";
      }
    }

    final updated = report.copyWith(confirmedBy: [...report.confirmedBy, 'me']);
    placeReports = [...placeReports]..[i] = updated;

    if (report.reporterId != 'me') _award(2); // "confirm someone else's report"
    // The verification bonus goes to whoever posted it, and only when this
    // confirm is what actually pushed it over the line (never re-awarded
    // for every confirm after the 8th).
    if (!report.verified && updated.verified && report.reporterId == 'me') {
      _award(report.kind == ReportKind.police || report.kind == ReportKind.shutdown ? 20 : 15);
    }
    _recordNightActivity();
    notifyListeners();
    _persist();
    return null;
  }

  /// Pulls back a report you submitted by mistake. Only the original
  /// reporter can retract it (no removing someone else's report), and once
  /// it's gone its confirmations go with it — there's nothing left to
  /// re-report under that id, a fresh submitReport starts over from 0 the
  /// same as if the kind had just been superseded.
  String? retractReport(String reportId) {
    final i = placeReports.indexWhere((r) => r.id == reportId);
    if (i == -1) return null; // already gone — nothing to do
    if (placeReports[i].reporterId != 'me') return "You can only remove a report you submitted.";
    placeReports = [...placeReports]..removeAt(i);
    notifyListeners();
    _persist();
    return null;
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

  /// Creates a REAL Supabase account — this is the first point where FUNKY
  /// actually talks to the backend (see supabase/schema.sql). A trigger on
  /// that project creates the matching `profiles` row server-side the
  /// instant this succeeds. If the project has email confirmation turned on
  /// (the Supabase default), Supabase hands back a user but no session yet
  /// — there's nothing to sign in as until the confirmation link is
  /// clicked, so this reports that back as its "error" (really an
  /// instruction) rather than claiming signedIn.
  Future<String?> signUp(String email, String password) async {
    final emailError = validateEmail(email);
    if (emailError != null) return emailError;
    final pwError = validatePassword(password);
    if (pwError != null) return pwError;
    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: email.trim(),
        password: password,
      );
      if (response.session == null) {
        return 'Check your email to confirm your account, then log in.';
      }
      accountEmail = response.user?.email;
      supabaseUserId = response.user?.id;
      signedIn = true;
      notifyListeners();
      _persist();
      _startRemoteSync();
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't create an account — check your connection and try again.";
    }
  }

  Future<String?> signIn(String email, String password) async {
    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (response.session == null) return 'Email or password is wrong.';
      accountEmail = response.user?.email;
      supabaseUserId = response.user?.id;
      signedIn = true;
      notifyListeners();
      _persist();
      _startRemoteSync();
      return null;
    } on AuthException catch (_) {
      return 'Email or password is wrong.';
    } catch (_) {
      return "Couldn't log in — check your connection and try again.";
    }
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // Best-effort — fall through and clear local state either way below,
      // so a network hiccup never traps someone in a "signed in" UI with no
      // way to actually get out of it.
    }
    _stopRemoteSync();
    // So a shared device doesn't keep showing the account that just signed
    // out's synced Stories/DMs/profiles to whoever uses it next.
    _clearRemoteData();
    signedIn = false;
    accountEmail = null;
    supabaseUserId = null;
    notifyListeners();
    _persist();
  }

  /// Re-signs-in with the current password first — proof you're really you
  /// — before asking Supabase to change anything sensitive. Supabase's
  /// "secure email change" sends a confirmation link to the new address (and
  /// often the old one too) before it actually takes effect, so accountEmail
  /// deliberately isn't updated here yet; load()/signIn() will pick up the
  /// real new address once the link is clicked and a session is re-derived.
  Future<String?> changeEmail(String newEmail, String currentPassword) async {
    if (!signedIn || accountEmail == null) return 'Log in first.';
    final error = validateEmail(newEmail);
    if (error != null) return error;
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: accountEmail!, password: currentPassword);
      await Supabase.instance.client.auth.updateUser(UserAttributes(email: newEmail.trim()));
      return "Check your new email's inbox for a confirmation link — it won't change until you click it.";
    } on AuthException catch (_) {
      return 'Current password is wrong.';
    } catch (_) {
      return "Couldn't update your email — check your connection and try again.";
    }
  }

  /// Sends a REAL password-reset email via Supabase. Unlike the old local
  /// mock, this can no longer just hand you a new-password field directly —
  /// there's no way to prove you own the inbox at [email] without an actual
  /// emailed link. NOTE: this app doesn't have deep linking wired up yet to
  /// catch that link and bring someone back in to actually set the new
  /// password, so for now this only gets as far as "the email is sent" —
  /// finishing that loop is follow-up work once deep linking exists.
  Future<String?> resetPassword(String email) async {
    final emailError = validateEmail(email);
    if (emailError != null) return emailError;
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email.trim());
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't send the reset email — check your connection and try again.";
    }
  }

  Future<String?> changePassword(String currentPassword, String newPassword) async {
    if (!signedIn || accountEmail == null) return 'Log in first.';
    final error = validatePassword(newPassword);
    if (error != null) return error;
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: accountEmail!, password: currentPassword);
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: newPassword));
      return null;
    } on AuthException catch (_) {
      return 'Current password is wrong.';
    } catch (_) {
      return "Couldn't update your password — check your connection and try again.";
    }
  }

  // --- Real backend sync: Stories + DMs -------------------------------
  // Only Stories and 1:1 DMs are wired to the real Supabase backend so far
  // (see supabase/schema.sql) — friends and the shared area Live Chat are
  // still local-only. Live Chat in particular has no matching table at all
  // to wire up: `messages` is strictly 1:1 (sender/recipient columns, no
  // 'room' or anonymous concept), so it would need its own new table and
  // policies, not just new code here.
  //
  // Everything below only ever runs while signedIn with a real
  // supabaseUserId (see _startRemoteSync's callers: signUp, signIn, and
  // load() when a session already exists), and is torn down again on
  // signOut (_stopRemoteSync + _clearRemoteData) so a shared device doesn't
  // keep showing the previous account's synced content to whoever uses it
  // next.
  //
  // Identity note: your OWN content is always stored/displayed locally
  // under the 'me' sentinel id, same as every other local list in this
  // file — a remote row authored by your own supabaseUserId gets
  // translated to 'me' the moment it's read (see _storyFromRow/
  // _messageFromRow); a remote row authored by anyone else keeps their real
  // uuid as the id, and _ensurePeopleFor fetches a Person record for it
  // from `profiles` so the rest of the UI (FunkyAvatar, FunkyHandle,
  // PersonProfileScreen, …) has something to render.

  RealtimeChannel? _storiesChannel;
  RealtimeChannel? _storyViewsChannel;
  RealtimeChannel? _storyLikesChannel;
  RealtimeChannel? _messagesChannel;

  // Every story/message/person id that came from the real backend, tracked
  // just so signOut (_clearRemoteData) can cleanly drop them again.
  final Set<String> _remoteStoryIds = {};
  final Set<String> _remoteMessageIds = {};
  final Set<String> _remotePersonIds = {};

  void _startRemoteSync() {
    final uid = supabaseUserId;
    if (uid == null) return;
    _stopRemoteSync();
    unawaited(_fetchRemoteStories());
    unawaited(_fetchRemoteMessages());

    final client = Supabase.instance.client;
    _storiesChannel = client.channel('public:stories:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'stories',
        callback: (payload) => _onRemoteStoryInsert(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'stories',
        callback: (payload) => _onRemoteStoryDelete(payload.oldRecord),
      )
      ..subscribe();

    _storyViewsChannel = client.channel('public:story_views:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'story_views',
        callback: (payload) => _onRemoteStoryViewInsert(payload.newRecord),
      )
      ..subscribe();

    _storyLikesChannel = client.channel('public:story_likes:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'story_likes',
        callback: (payload) => _onRemoteStoryLikeChange(payload.newRecord, true),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'story_likes',
        callback: (payload) => _onRemoteStoryLikeChange(payload.oldRecord, false),
      )
      ..subscribe();

    _messagesChannel = client.channel('public:messages:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'messages',
        callback: (payload) => _onRemoteMessageInsert(payload.newRecord),
      )
      ..subscribe();
  }

  void _stopRemoteSync() {
    final client = Supabase.instance.client;
    for (final channel in [_storiesChannel, _storyViewsChannel, _storyLikesChannel, _messagesChannel]) {
      if (channel != null) client.removeChannel(channel);
    }
    _storiesChannel = null;
    _storyViewsChannel = null;
    _storyLikesChannel = null;
    _messagesChannel = null;
  }

  void _clearRemoteData() {
    stories = stories.where((s) => !_remoteStoryIds.contains(s.id)).toList();
    messages = messages.where((m) => !_remoteMessageIds.contains(m.id)).toList();
    people = {for (final entry in people.entries) if (!_remotePersonIds.contains(entry.key)) entry.key: entry.value};
    _remoteStoryIds.clear();
    _remoteMessageIds.clear();
    _remotePersonIds.clear();
  }

  void _fireAndForgetInsert(String table, Map<String, dynamic> data) {
    unawaited(() async {
      try {
        await Supabase.instance.client.from(table).insert(data);
      } catch (_) {
        // Best-effort — the local copy already updated on this device;
        // if this fails (offline, etc.) the server just won't have it
        // until a retry succeeds.
      }
    }());
  }

  void _fireAndForgetUpdate(String table, Map<String, dynamic> data, String matchId) {
    unawaited(() async {
      try {
        await Supabase.instance.client.from(table).update(data).eq('id', matchId);
      } catch (_) {
        // Best-effort — see _fireAndForgetInsert.
      }
    }());
  }

  /// Fetches a Person record from `profiles` for every id in [uids] this
  /// device doesn't already know about (skipping 'me' and anyone already
  /// in [people], demo accounts included) so FunkyAvatar/FunkyHandle/
  /// PersonProfileScreen all have something real to render for a story or
  /// DM from an actual other account.
  Future<void> _ensurePeopleFor(Iterable<String> uids) async {
    final toFetch = uids.where((id) => id != 'me' && !people.containsKey(id)).toSet();
    if (toFetch.isEmpty) return;
    try {
      final rows = await Supabase.instance.client.from('profiles').select().inFilter('id', toFetch.toList());
      final updated = Map<String, Person>.from(people);
      for (final row in rows) {
        final id = row['id'] as String;
        updated[id] = _personFromProfileRow(row);
        _remotePersonIds.add(id);
      }
      people = updated;
      notifyListeners();
    } catch (_) {
      // Offline — these ids just render with a '?' avatar / a placeholder
      // handle until the next successful sync.
    }
  }

  Person _personFromProfileRow(Map<String, dynamic> row) {
    final id = row['id'] as String;
    return Person(
      id: id,
      handle: (row['handle'] as String?) ?? 'funky_${id.substring(0, 8)}',
      bio: (row['bio'] as String?) ?? '',
      since: 0,
      points: (row['points'] as num?)?.toInt() ?? 0,
      friends: const [],
      friendRequestsSent: const [],
      friendRequestsReceived: const [],
      muted: const [],
      anon: false,
      session: sessionKey(),
      votes: const {},
      seen: const [],
      likes: const [],
      // Their avatar_url (if they ever set one) is a remote URL, not a
      // local file path — FunkyAvatar only renders local files right now,
      // so a real account just falls back to its initial-letter circle
      // until avatars are part of this sync too.
      photoPath: null,
    );
  }

  /// Builds a local Story from one `stories` row — resolving its media to a
  /// temporary signed download URL when it has any, since a real row never
  /// carries a local file path. Returns null for a malformed row rather
  /// than throwing, so one bad row can't break the whole fetch/subscription.
  Future<Story?> _storyFromRow(Map<String, dynamic> row, {List<String> views = const [], List<String> likes = const []}) async {
    final rowUid = row['uid'] as String?;
    final id = row['id'] as String?;
    if (rowUid == null || id == null) return null;
    final createdAtRaw = row['created_at'] as String?;
    final createdAt = createdAtRaw != null ? DateTime.parse(createdAtRaw).toLocal() : DateTime.now();
    final mediaPath = row['media_path'] as String?;
    final isVideo = row['is_video'] as bool? ?? false;
    String? mediaUrl;
    if (mediaPath != null) {
      try {
        // An hour is generous for how long a Story viewer session could
        // plausibly stay open on one Story; it's re-resolved fresh on
        // every fetch anyway, never cached past that.
        mediaUrl = await Supabase.instance.client.storage.from('stories').createSignedUrl(mediaPath, 3600);
      } catch (_) {
        // No access (shouldn't happen if the row itself was visible) or
        // offline — the Story still shows with its caption/placeholder.
      }
    }
    return Story(
      id: id,
      t: createdAt.millisecondsSinceEpoch,
      uid: rowUid == supabaseUserId ? 'me' : rowUid,
      text: row['text'] as String?,
      place: row['place_id'] as String?,
      placeName: row['place_name'] as String?,
      anon: row['anon'] as bool? ?? false,
      session: sessionKey(createdAt),
      views: views,
      likes: likes,
      savedToTimeline: row['saved_to_timeline'] as bool? ?? false,
      imageUrl: mediaUrl != null && !isVideo ? mediaUrl : null,
      videoUrl: mediaUrl != null && isVideo ? mediaUrl : null,
    );
  }

  /// Merges freshly-fetched/updated remote Stories into [stories] — a real
  /// Story you posted FROM THIS DEVICE already has a local imagePath/
  /// videoPath from when you captured it, so that local copy's file
  /// reference is kept and only its server-tracked fields (views/likes/
  /// savedToTimeline) are refreshed from [fetched]; anything else (someone
  /// else's Story, or your own fetched back on a second device) is used
  /// as-is, signed URL and all.
  void _mergeRemoteStories(List<Story> fetched) {
    if (fetched.isEmpty) return;
    final byId = {for (final s in stories) s.id: s};
    for (final story in fetched) {
      _remoteStoryIds.add(story.id);
      final existingLocal = byId[story.id];
      if (existingLocal != null && (existingLocal.imagePath != null || existingLocal.videoPath != null)) {
        byId[story.id] = existingLocal.copyWith(views: story.views, likes: story.likes, savedToTimeline: story.savedToTimeline);
      } else {
        byId[story.id] = story;
      }
    }
    stories = byId.values.toList();
    notifyListeners();
    _persist();
  }

  Future<void> _fetchRemoteStories() async {
    if (supabaseUserId == null) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('stories').select().order('created_at');
      final viewRows = await client.from('story_views').select();
      final likeRows = await client.from('story_likes').select();
      final viewsByStory = <String, List<String>>{};
      for (final v in viewRows) {
        final sid = v['story_id'] as String;
        (viewsByStory[sid] ??= []).add(v['viewer_id'] as String);
      }
      final likesByStory = <String, List<String>>{};
      for (final l in likeRows) {
        final sid = l['story_id'] as String;
        (likesByStory[sid] ??= []).add(l['liker_id'] as String);
      }
      final fetched = <Story>[];
      for (final row in rows) {
        final story = await _storyFromRow(row, views: viewsByStory[row['id']] ?? const [], likes: likesByStory[row['id']] ?? const []);
        if (story != null) fetched.add(story);
      }
      await _ensurePeopleFor(fetched.map((s) => s.uid));
      _mergeRemoteStories(fetched);
    } catch (_) {
      // Offline or a transient error — keep whatever's already showing;
      // the realtime subscription (or the next sign-in) will catch up.
    }
  }

  void _onRemoteStoryInsert(Map<String, dynamic> row) {
    unawaited(() async {
      final story = await _storyFromRow(row);
      if (story == null) return;
      await _ensurePeopleFor([story.uid]);
      _mergeRemoteStories([story]);
    }());
  }

  void _onRemoteStoryDelete(Map<String, dynamic> oldRow) {
    final id = oldRow['id'] as String?;
    if (id == null) return;
    stories = stories.where((s) => s.id != id).toList();
    _remoteStoryIds.remove(id);
    notifyListeners();
    _persist();
  }

  void _onRemoteStoryViewInsert(Map<String, dynamic> row) {
    final storyId = row['story_id'] as String?;
    final viewerId = row['viewer_id'] as String?;
    if (storyId == null || viewerId == null) return;
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1 || stories[i].views.contains(viewerId)) return;
    stories = [...stories]..[i] = stories[i].copyWith(views: [...stories[i].views, viewerId]);
    notifyListeners();
    _persist();
  }

  void _onRemoteStoryLikeChange(Map<String, dynamic> row, bool added) {
    final storyId = row['story_id'] as String?;
    final likerId = row['liker_id'] as String?;
    if (storyId == null || likerId == null) return;
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1) return;
    final current = stories[i].likes;
    final next = added ? (current.contains(likerId) ? current : [...current, likerId]) : current.where((id) => id != likerId).toList();
    stories = [...stories]..[i] = stories[i].copyWith(likes: next);
    notifyListeners();
    _persist();
  }

  /// Builds a local ChatMessage from one `messages` row — same 'me'
  /// translation and dmRoomId addressing as everywhere else, so DMs synced
  /// from the real backend slot into exactly the same [messages] list (and
  /// [dmConversations]/[messagesFor]) as a local/demo DM already does.
  ChatMessage? _messageFromRow(Map<String, dynamic> row) {
    final uid = supabaseUserId;
    if (uid == null) return null;
    final senderId = row['sender_id'] as String?;
    final recipientId = row['recipient_id'] as String?;
    final id = row['id'] as String?;
    if (senderId == null || recipientId == null || id == null) return null;
    final otherId = senderId == uid ? recipientId : senderId;
    final createdAtRaw = row['created_at'] as String?;
    final createdAt = createdAtRaw != null ? DateTime.parse(createdAtRaw).toLocal() : DateTime.now();
    return ChatMessage(
      id: id,
      t: createdAt.millisecondsSinceEpoch,
      room: dmRoomId('me', otherId),
      uid: senderId == uid ? 'me' : senderId,
      text: row['text'] as String? ?? '',
      anon: false,
    );
  }

  Future<void> _fetchRemoteMessages() async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.from('messages').select().order('created_at');
      final fetched = <ChatMessage>[];
      final otherIds = <String>{};
      for (final row in rows) {
        final msg = _messageFromRow(row);
        if (msg == null) continue;
        fetched.add(msg);
        _remoteMessageIds.add(msg.id);
        final sender = row['sender_id'] as String;
        final recipient = row['recipient_id'] as String;
        otherIds.add(sender == supabaseUserId ? recipient : sender);
      }
      await _ensurePeopleFor(otherIds);
      final existingIds = messages.map((m) => m.id).toSet();
      final newOnes = fetched.where((m) => !existingIds.contains(m.id)).toList();
      if (newOnes.isNotEmpty) {
        messages = [...messages, ...newOnes];
        notifyListeners();
        _persist();
      }
    } catch (_) {
      // Offline — DMs sent/received while this device couldn't reach
      // Supabase show up once the realtime channel reconnects or the next
      // sign-in triggers a fresh fetch.
    }
  }

  void _onRemoteMessageInsert(Map<String, dynamic> row) {
    final msg = _messageFromRow(row);
    if (msg == null) return;
    _remoteMessageIds.add(msg.id);
    // Already here — either this device sent it (sendDirectMessage adds it
    // straight from the insert response) or a duplicate delivery of the
    // same realtime event.
    if (messages.any((m) => m.id == msg.id)) return;
    unawaited(() async {
      await _ensurePeopleFor([msg.uid]);
      messages = [...messages, msg];
      notifyListeners();
      _persist();
    }());
  }

  @override
  void dispose() {
    _stopRemoteSync();
    super.dispose();
  }
}
