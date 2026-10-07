import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/push_service.dart';
import 'geo.dart';
import 'group_models.dart';
import 'mock_data.dart';
import 'models.dart';
import 'notification_models.dart';
import 'place_photo.dart';
import 'place_rating.dart';
import 'session.dart';

const _storageKey = 'funky.store.v1';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

// Real accounts always have a Supabase uuid for an id; the old demo people
// ('p1', 'p2', 'p3', …) never did. Used by the one-time go-live cleanup in
// load() to strip leftover demo ids out of a device's saved friends list.
final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
bool _isRealPersonId(String id) => _uuidPattern.hasMatch(id);

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
  String? get coverUrl => place.coverUrl;
  String? get photoUrl => place.photoUrl;
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
  // The owner (the one hardcoded email) is always an admin; the owner can also
  // promote other accounts, which shows up here via profiles.is_admin.
  bool _remoteAdmin = false;
  bool get isOwner => signedIn && accountEmail?.toLowerCase() == _adminEmail;
  bool get isAdmin => signedIn && (accountEmail?.toLowerCase() == _adminEmail || _remoteAdmin);

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

  bool isBanned(String personId) => bannedUserIds.contains(personId) || _remoteBannedIds.contains(personId);

  // Banned on the real backend (profiles.banned) — everyone's app learns
  // about it from the profile rows, so a ban actually takes effect for
  // everybody, not just on the admin's phone.
  final Set<String> _remoteBannedIds = {};

  // True when YOUR OWN account has been banned by the admin — posting,
  // messaging, adding places, etc. are all blocked (the server also
  // refuses them; this just fails fast with a clear message).
  bool selfBanned = false;
  static const String _bannedMessage = 'Your account has been suspended.';

  // Whether the one-time go-live cleanup (see load()) has already run on
  // this device — wipes everything that came from the old demo data
  // (sample people/places/polls/chat, test places and chats, fake
  // confirmations, the seeded p1/p2 "friends") exactly once, then never
  // again. False for any install from before go-live, which is exactly the
  // install that needs it; a brand-new install has nothing to clean.
  bool _goLiveCleaned = false;

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
    if (_isRealPersonId(personId)) {
      _remoteBannedIds.add(personId);
      _fireAndForgetRpc('admin_set_banned', {'target': personId, 'flag': true});
      _fireAndForgetFriendshipRemove(personId);
    }
  }

  /// Admin-only — lifts a ban. Doesn't restore the friendship that banning
  /// severed; that's a fresh Add Friend if either side wants it back.
  void unbanUser(String personId) {
    if (!isAdmin) return;
    final next = Set<String>.from(bannedUserIds)..remove(personId);
    bannedUserIds = next;
    _remoteBannedIds.remove(personId);
    notifyListeners();
    _persist();
    if (_isRealPersonId(personId)) {
      _fireAndForgetRpc('admin_set_banned', {'target': personId, 'flag': false});
    }
  }

  /// Everyone currently banned, from either source (this device's local
  /// set or the backend), for the admin panel's list.
  Set<String> get allBannedIds => {...bannedUserIds, ..._remoteBannedIds};

  /// Admin-only — gives [personId] [amount] FUNKY Points (negative takes
  /// some away). Can be used as many times as you like. For someone else
  /// it goes through the server (their app picks it up live); for yourself
  /// it just adds to your own total. Returns null on success or a message.
  Future<String?> adminGivePoints(String personId, int amount) async {
    if (!isAdmin) return 'Admins only.';
    if (amount == 0) return null;
    if (personId == 'me') {
      final next = me.points + amount;
      me = me.copyWith(points: next < 0 ? 0 : next);
      notifyListeners();
      _persist();
      return null;
    }
    if (!_isRealPersonId(personId) || !signedIn) return 'That account is not synced yet.';
    try {
      await Supabase.instance.client.rpc('admin_give_points', params: {'target': personId, 'amount': amount});
      final p = people[personId];
      if (p != null) {
        final next = p.points + amount;
        people = {...people, personId: p.copyWith(points: next < 0 ? 0 : next)};
        notifyListeners();
      }
      return null;
    } catch (e) {
      final why = _friendlySendError(e);
      return "Couldn't give points — $why";
    }
  }

  /// Owner-only: makes another account an admin (or takes it away). The
  /// server enforces this; the new admin sees the Admin panel and gets the
  /// gold badge everywhere.
  Future<String?> adminSetAdmin(String personId, bool makeAdmin) async {
    if (!isOwner) return 'Only the FUNKY owner can do that.';
    if (!_isRealPersonId(personId) || !signedIn) return 'That account is not synced yet.';
    try {
      await Supabase.instance.client.rpc('admin_set_admin', params: {'target': personId, 'flag': makeAdmin});
      final p = people[personId];
      if (p != null) {
        people = {...people, personId: p.copyWith(isAdminUser: makeAdmin)};
        notifyListeners();
      }
      return null;
    } catch (e) {
      return "Couldn't change admin access — ${_friendlySendError(e)}";
    }
  }

  /// A quick health check of the Supabase side — which tables/functions the
  /// app needs actually exist. Returns (label, ok, detail) rows for the
  /// admin panel, so a missing SQL file is obvious instead of every feature
  /// just saying "check your connection".
  Future<List<(String, bool, String)>> checkBackend() async {
    final client = Supabase.instance.client;
    final results = <(String, bool, String)>[];
    Future<void> table(String label, String name, [String cols = '*']) async {
      try {
        await client.from(name).select(cols).limit(1);
        results.add((label, true, ''));
      } catch (e) {
        results.add((label, false, _friendlySendError(e)));
      }
    }
    await table('Profiles (base)', 'profiles', 'id,handle,points');
    await table('Profiles (phase 2 columns)', 'profiles', 'bonus_points,style,banned,is_admin,move,move_streak');
    await table('Places', 'places', 'id');
    await table('Polls', 'polls', 'id');
    await table('Place reports', 'place_reports', 'id');
    await table('Live chat', 'chat_messages', 'id');
    await table('DM photo/video columns', 'messages', 'id,media_path,read_at');
    await table('Chat reactions (phase 3)', 'chat_reactions', 'message_id');
    await table('Place cover photos (phase 3)', 'places', 'cover_url');
    await table('Place ratings (phase 9)', 'place_ratings', 'place_id');
    await table('Place pictures + profile reports (phase 10)', 'profile_reports', 'id');
    await table('Place approved picture (phase 10)', 'places', 'photo_url');
    try {
      await client.rpc('is_admin');
      results.add(('Admin functions', true, ''));
    } catch (e) {
      results.add(('Admin functions', false, _friendlySendError(e)));
    }
    try {
      await client.rpc('random_handle');
      results.add(('Random usernames (phase 4)', true, ''));
    } catch (e) {
      results.add(('Random usernames (phase 4)', false, _friendlySendError(e)));
    }
    try {
      await client.rpc('admin_set_admin', params: {'target': '00000000-0000-0000-0000-000000000000', 'flag': false});
      results.add(('Delegated admins (phase 5)', true, ''));
    } catch (e) {
      final m = e.toString().toLowerCase();
      // "admin only"/"owner only" means the function exists and refused us
      // (or ran against a nonexistent id) — which is a pass.
      final exists = !(m.contains('could not find the function') || m.contains('pgrst202') || m.contains('42883'));
      results.add(('Delegated admins (phase 5)', exists, exists ? '' : 'Run the latest SQL file (phase 5).'));
    }
    try {
      final raw = await client.rpc('backend_status');
      final st = raw is Map ? raw : <dynamic, dynamic>{};
      results.add(('Your profile row exists', st['profile_exists'] == true, st['profile_exists'] == true ? '' : 'Run RUN_ALL.sql, then reopen the app.'));
      results.add(('Profile-picture storage is public', st['avatars_public'] == true, st['avatars_public'] == true ? '' : 'Run RUN_ALL.sql (phase 6).'));
      results.add(('Place-photo storage is public', st['place_covers_public'] == true, st['place_covers_public'] == true ? '' : 'Run RUN_ALL.sql (phase 6).'));
      results.add(('Photo/video DM storage', st['dm_media_exists'] == true, st['dm_media_exists'] == true ? '' : 'Run RUN_ALL.sql (phase 2).'));
      results.add(('Sign-up creates profiles', st['signup_trigger'] == true, st['signup_trigger'] == true ? '' : 'Run RUN_ALL.sql (phase 6).'));
    } catch (e) {
      results.add(('Backend health (phase 6)', false, 'Run the latest RUN_ALL.sql in Supabase.'));
    }
    return results;
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
    if (_remotePlaceIds.remove(placeId)) {
      _fireAndForgetRemote(() => Supabase.instance.client.from('places').delete().eq('id', placeId));
    }
  }

  /// Admin-only — permanently deletes one chat message, area-chat or a DM.
  /// Silently does nothing for a non-admin account.
  void deleteMessage(String messageId) {
    if (!isAdmin) return;
    messages = messages.where((m) => m.id != messageId).toList();
    notifyListeners();
    _persist();
    if (_remoteChatIds.remove(messageId)) {
      _fireAndForgetRemote(() => Supabase.instance.client.from('chat_messages').delete().eq('id', messageId));
    }
  }

  /// Admin-only — permanently deletes a poll (and scrubs its id out of
  /// everyone's votes, including your own, so a stray old vote can't ever
  /// point at something that no longer exists). Silently does nothing for
  /// a non-admin account.
  void deletePoll(String pollId) {
    if (!isAdmin) return;
    polls = polls.where((p) => p.id != pollId).toList();
    me = me.copyWith(votes: Map<String, int>.from(me.votes)..remove(pollId));
    people = {
      for (final entry in people.entries) entry.key: entry.value.copyWith(votes: Map<String, int>.from(entry.value.votes)..remove(pollId)),
    };
    notifyListeners();
    _persist();
  }

  /// Admin-only — sets your own points to the max, comfortably past every
  /// level title and badge threshold (see levelTitles in models.dart), so
  /// the points/levels/badges UI can be tested without actually grinding
  /// for it. Silently does nothing for a non-admin account.
  void maxOutMyPoints() {
    if (!isAdmin) return;
    me = me.copyWith(points: 999999);
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
    if (_remotePlaceIds.contains(placeId)) {
      _fireAndForgetRemote(
        () => Supabase.instance.client.from('places').update({'admin_verified': verified}).eq('id', placeId),
      );
    }
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
    if (selfBanned) return _bannedMessage;
    final current = placeConfirmations[placeId] ?? const [];
    if (current.contains('me')) return null;
    if (_tooSoon('confirmPlace', 800)) return null;
    placeConfirmations = {...placeConfirmations, placeId: [...current, 'me']};
    notifyListeners();
    _persist();
    final uid = supabaseUserId;
    if (signedIn && uid != null && _remotePlaceIds.contains(placeId)) {
      _fireAndForgetInsert('place_confirmations', {'place_id': placeId, 'user_id': uid});
    }
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

  /// Sets (or, with null, clears) your custom name color — [argb] is a
  /// Color.toARGB32() value. Points-gated like every other name style
  /// (see canUseNameColor); a color picked before that unlock is ignored.
  void setNameColor(int? argb) {
    if (argb == null) {
      me = me.copyWith(clearNameColor: true);
    } else if (canUseNameColor(me.points)) {
      me = me.copyWith(nameColor: argb);
    } else {
      return;
    }
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
  // Defense-in-depth alongside the 240-char `maxLength` already set on the
  // chat/DM TextFields themselves — this is what actually gets saved/sent
  // no matter how the text got here (paste, a future API caller, etc).
  static const int _maxMessageLength = 240;

  // --- Limits: keep anyone from spamming the app into a crash ----------
  // Every one of these is enforced HERE in the store (the UI's own
  // maxLength/disabled buttons are just the friendly first line of defense),
  // so no code path — a paste, a double-tap, a future caller — can get past
  // them. A signed-in FUNKY Admin is exempt from the per-day caps (see
  // isAdmin), never from the length caps.
  static const int maxStoriesPerDay = 30;
  static const int maxReportsPerDay = 20;
  static const int maxPendingFriendRequests = 40;
  static const int maxPlaceNameLength = 40;
  static const int maxPlaceAddressLength = 80;
  static const int maxPollQuestionLength = 80;
  static const int maxPollOptionLength = 40;
  static const int maxPollOptions = 8;
  static const int maxStoryTextLength = 200;
  static const int maxReportDetailLength = 20;
  static const int maxSearchLength = 30;
  // Oldest messages beyond this are dropped from memory (and never written
  // to disk) so a long-running chat can't grow without bound.
  static const int maxMessagesKept = 1500;
  static const int maxPersistedMessages = 200;
  // A Story/DM photo or video bigger than this never gets uploaded (the
  // camera already caps videos at 15s; this is the backstop for a library
  // pick or a weird codec).
  static const int maxStoryUploadBytes = 60 * 1024 * 1024;
  // Direct-message snaps: a video must be under 25 MB (matches the dm_media
  // bucket's own server-side limit) and a photo under 12 MB.
  static const int maxDmVideoBytes = 25 * 1024 * 1024;
  static const int maxDmImageBytes = 12 * 1024 * 1024;

  final Map<String, int> _lastActionAt = {};

  /// True if [key] already fired less than [cooldownMs] ago (and so should
  /// be ignored); otherwise records now as its latest time and returns
  /// false. The one tiny helper every rate limit below shares.
  bool _tooSoon(String key, int cooldownMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastActionAt[key];
    if (last != null && now - last < cooldownMs) return true;
    _lastActionAt[key] = now;
    return false;
  }

  /// Why you can't post another Story right now, or null if you can — a
  /// short cooldown between posts plus a per-day cap (not for an Admin).
  String? storyBlockReason() {
    if (!isAdmin) {
      final today = sessionKey();
      final postedToday = stories.where((s) => s.uid == 'me' && s.session == today).length;
      if (postedToday >= maxStoriesPerDay) return "That's the limit for today — you can post $maxStoriesPerDay Stories a day.";
    }
    final last = _lastActionAt['story'];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last != null && now - last < 5000) return 'Easy — wait a few seconds before posting another Story.';
    return null;
  }

  /// Why you can't submit another place report right now, or null.
  String? reportBlockReason() {
    if (!isAdmin) {
      final today = sessionKey();
      final startOfSession = DateTime.tryParse(today)?.add(const Duration(hours: resetHour)).millisecondsSinceEpoch ?? 0;
      final mine = placeReports.where((r) => r.reporterId == 'me' && r.t >= startOfSession).length;
      if (mine >= maxReportsPerDay) return "That's the limit for today — you can submit $maxReportsPerDay reports a day.";
    }
    final last = _lastActionAt['report'];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last != null && now - last < 4000) return 'Easy — wait a few seconds before submitting another report.';
    return null;
  }

  // Everything starts empty — FUNKY is live now, so there's no demo people,
  // places, polls, chat, or Stories to seed. What shows up comes from real
  // accounts (and, for places added/confirmed on this device, the local
  // lists below).
  AppStore() {
    people = {};
    places = [];
    polls = [];
    messages = [];
    stories = [];
    placeReports = [];
    placeConfirmations = {};
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      final currentSession = sessionKey();
      if (raw != null) {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        final storedSession = parsed['session'] as String?;
        // The one-time go-live cleanup (see _goLiveCleaned): on the first
        // launch of a build that has it, the old local test places, polls,
        // chats, reports, venue confirmations, and admin verifications are
        // all dropped, and the seeded demo friends/votes are stripped off
        // 'me' — everything that only ever existed because of the demo data.
        // Your own Stories (Memories), points, name styling, and profile
        // are kept.
        final alreadyCleaned = parsed['goLiveCleaned'] as bool? ?? false;
        final rawMe = Person.fromJson(parsed['me'] as Map<String, dynamic>);
        final parsedMe = alreadyCleaned
            ? rawMe
            : rawMe.copyWith(
                friends: rawMe.friends.where(_isRealPersonId).toList(),
                friendRequestsSent: rawMe.friendRequestsSent.where(_isRealPersonId).toList(),
                friendRequestsReceived: rawMe.friendRequestsReceived.where(_isRealPersonId).toList(),
                votes: const {},
                clearMove: true,
              );
        final parsedPlaces = alreadyCleaned
            ? (parsed['places'] as List).map((e) => Place.fromJson(e as Map<String, dynamic>)).toList()
            : <Place>[];
        final parsedPolls = alreadyCleaned
            ? (parsed['polls'] as List).map((e) => Poll.fromJson(e as Map<String, dynamic>)).toList()
            : <Poll>[];
        final parsedMessages = alreadyCleaned
            ? (parsed['messages'] as List).map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList()
            : <ChatMessage>[];
        // A message that was still 'sending' when the app last closed never
        // finished — show it as failed (tap to retry) instead of spinning forever.
        final parsedMessagesFixed = parsedMessages.map((m) => m.status == 'sending' ? m.copyWith(status: 'failed') : m).toList();
        final parsedStories = (parsed['stories'] as List).map((e) => Story.fromJson(e as Map<String, dynamic>)).toList();
        final parsedReports = alreadyCleaned
            ? ((parsed['placeReports'] as List?) ?? const []).map((e) => PlaceReport.fromJson(e as Map<String, dynamic>)).toList()
            : <PlaceReport>[];
        _goLiveCleaned = true;
        _lastUserId = parsed['lastUserId'] as String?;
        _appliedBonus = (parsed['appliedBonus'] as num?)?.toInt() ?? 0;
        final covers = parsed['placeCovers'];
        if (covers is Map) {
          _localPlaceCovers
            ..clear()
            ..addAll({for (final e in covers.entries) e.key.toString(): e.value.toString()});
        }
        // Which venues 'me' has personally vouched for — never tied to
        // tonight's session, re-applied on top of whatever's loaded either
        // way (a real confirm should never be lost on reload).
        final myVenueConfirmations = alreadyCleaned
            ? ((parsed['myVenueConfirmations'] as List?) ?? const []).map((e) => e as String).toSet()
            : <String>{};
        for (final placeId in myVenueConfirmations) {
          final current = placeConfirmations[placeId] ?? const [];
          if (!current.contains('me')) {
            placeConfirmations = {...placeConfirmations, placeId: [...current, 'me']};
          }
        }

        // Also never tied to tonight's session — a FUNKY Admin verification
        // should survive the 2 PM reset the same way the account itself does.
        adminVerifiedPlaceIds = alreadyCleaned
            ? ((parsed['adminVerifiedPlaceIds'] as List?) ?? const []).map((e) => e as String).toSet()
            : <String>{};

        // Same reasoning — a ban shouldn't quietly lift itself at 2 PM.
        bannedUserIds = ((parsed['bannedUserIds'] as List?) ?? const []).map((e) => e as String).toSet();

        // Whether 'me' has viewed/liked someone ELSE's story — their story
        // content itself is never persisted (it's re-seeded fresh from the
        // demo data or the real backend every launch), but the fact that
        // YOU already saw/liked it needs to survive a restart too, the
        // same as every other bit of your own activity does. Re-applied by
        // story id onto whatever's in `stories` right now below, so it
        // only ever matters for a story id that still actually exists —
        // a stale id from a story that's since expired just no-ops.
        final myViewedStoryIds = ((parsed['myViewedStoryIds'] as List?) ?? const []).map((e) => e as String).toSet();
        final myLikedStoryIds = ((parsed['myLikedStoryIds'] as List?) ?? const []).map((e) => e as String).toSet();

        if (storedSession == currentSession) {
          me = parsedMe;
          places = _dedupeById([...places, ...parsedPlaces], (p) => p.id);
          polls = _dedupeById([...polls, ...parsedPolls], (p) => p.id);
          messages = _dedupeById([...messages, ...parsedMessagesFixed], (m) => m.id);
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
          placeReports = _dedupeById([...placeReports, ...parsedReports], (r) => r.id);
        } else {
          // Stale night — carry over only what survives the reset (rule 3).
          // Friends (and pending requests) stay, same as DMs — only the
          // tonight-only stuff (move, votes, seen/likes) gets wiped. Built
          // with copyWith off the saved profile (rather than a fresh Person
          // listing fields one by one) so every cosmetic/streak field —
          // name styling and color, the chosen title, the going streak —
          // survives the reset automatically instead of silently resetting
          // to its default every night.
          me = parsedMe.copyWith(
            session: currentSession,
            clearMove: true,
            votes: const {},
            seen: const [],
            likes: const [],
          );
          // Places are tonight-only too — but a place a FUNKY Admin has
          // verified outright keeps living across the reset (and, once
          // places sync with the backend, so does anything the crowd has
          // verified with 15+ confirmations — see _applyRemotePlaces).
          places = parsedPlaces.where((p) => adminVerifiedPlaceIds.contains(p.id)).toList();
          // Your own Stories are permanent (Memories), even though the
          // *place* records and everyone else's tonight-only Stories get
          // wiped at reset — this used to just drop `parsedStories`
          // entirely, which is why Memories kept losing photos/videos every
          // night. _persist() only ever writes 'me'-authored stories here,
          // so this merge is always just your own history.
          stories = _dedupeById([...stories, ...parsedStories], (s) => s.id);
          // DMs stay across the reset (only tonight's live chat is wiped).
          messages = _dedupeById([...messages, ...parsedMessagesFixed.where((m) => m.room.startsWith('dm_') || m.room.startsWith('grp_'))], (m) => m.id);
          justReset = true;
        }

        // Re-apply onto `stories` above (either branch) now that it's
        // settled — this is the actual fix for the "story goes back to
        // orange after closing and reopening the app" bug: without this,
        // views/likes recorded on someone ELSE's story were computed fine
        // in-session but never written anywhere _persist() looked at, so
        // they vanished the instant the app restarted and that story got
        // re-seeded. A ring/story that's no longer around (expired, or a
        // demo id that shifted) just silently no-ops here.
        if (myViewedStoryIds.isNotEmpty || myLikedStoryIds.isNotEmpty) {
          stories = stories.map((s) {
            final needsView = myViewedStoryIds.contains(s.id) && !s.views.contains('me');
            final needsLike = myLikedStoryIds.contains(s.id) && !s.likes.contains('me');
            if (!needsView && !needsLike) return s;
            return s.copyWith(
              views: needsView ? [...s.views, 'me'] : null,
              likes: needsLike ? [...s.likes, 'me'] : null,
            );
          }).toList();
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
      // Whatever happened above (a brand-new install with nothing to clean,
      // or a cleanup that just ran), the go-live cleanup never needs to run
      // again on this device.
      _goLiveCleaned = true;
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
      _listenForAuthChanges();
      // Pick location back up automatically on every launch instead of
      // waiting for a tap on LocationGate's "Enable location" button —
      // once you've actually granted it to the OS, requestLocation()
      // below resolves that silently (Geolocator.checkPermission() sees
      // it's already granted and never re-prompts), so this just quietly
      // restores it before you ever see a gate. If it's not granted yet
      // (first launch, or you denied it), this is exactly the same OS
      // prompt tapping the button would have triggered, just fired
      // automatically instead of waiting on you to find the button.
      requestLocation();
    }
  }

  Timer? _persistTimer;

  /// Coalesces a burst of changes (a flurry of reactions, taps, realtime
  /// events…) into a single disk write instead of one per call — the
  /// actual write is _persistNow, ~250 ms after the last request.
  Future<void> _persist() async {
    if (!loaded) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), () => unawaited(_persistNow()));
  }

  Future<void> _persistNow() async {
    if (!loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = {
        'session': sessionKey(),
        'me': me.toJson(),
        // Places live on the server now (shared with everyone), re-fetched
        // on every launch — nothing worth saving locally.
        'places': <Map<String, dynamic>>[],
        // Polls and reports live on the server now too.
        'polls': <Map<String, dynamic>>[],
        'messages': (() {
          final mine = messages.where((m) => m.uid == 'me').toList();
          final recent = mine.length > maxPersistedMessages ? mine.sublist(mine.length - maxPersistedMessages) : mine;
          return recent.map((m) => m.toJson()).toList();
        })(),
        'stories': stories.where((s) => s.uid == 'me').map((s) => s.toJson()).toList(),
        'placeReports': <Map<String, dynamic>>[],
        'myVenueConfirmations': placeConfirmations.entries.where((e) => e.value.contains('me')).map((e) => e.key).toList(),
        // accountEmail/signedIn/supabaseUserId are no longer written here —
        // they're derived fresh from Supabase's own session on every load()
        // instead (see there), so there's nothing real to persist locally
        // for them anymore.
        'adminVerifiedPlaceIds': adminVerifiedPlaceIds.toList(),
        'bannedUserIds': bannedUserIds.toList(),
        // Views/likes YOU put on someone ELSE's story — their story row
        // itself is excluded just above (`stories.where((s) => s.uid ==
        // 'me')`), so without this your own activity on it would be lost
        // on every restart (see load()'s re-apply step for the other half
        // of this fix).
        'myViewedStoryIds': stories.where((s) => s.uid != 'me' && s.views.contains('me')).map((s) => s.id).toList(),
        'myLikedStoryIds': stories.where((s) => s.uid != 'me' && s.likes.contains('me')).map((s) => s.id).toList(),
        'goLiveCleaned': _goLiveCleaned,
        'lastUserId': _lastUserId,
        'appliedBonus': _appliedBonus,
        'placeCovers': _localPlaceCovers,
      };
      await prefs.setString(_storageKey, jsonEncode(payload));
      // Anything that changed worth telling other people about (points,
      // going-to, streak, name style) rides along on the same debounce.
      _maybePushProfile();
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
      _syncLocationUp();
    } catch (_) {
      locationStatus = LocationStatus.denied;
      notifyListeners();
    }
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
      // Others' Stories arrive as signed URLs rather than local files —
      // those count too (before, only your own device's media ever did).
      if (s.videoPath == null && s.imagePath == null && s.videoUrl == null && s.imageUrl == null) continue;
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
    var q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    if (q.length > maxSearchLength) q = q.substring(0, maxSearchLength);
    // Escape LIKE wildcards so a typed % or _ can't turn this into a
    // match-everything query against the real profiles table.
    final remoteQ = q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
    final localMatches = people.values.where((p) => p.handle.toLowerCase().contains(q) && !isBanned(p.id)).toList();
    if (!signedIn || supabaseUserId == null) return localMatches;
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select()
          .ilike('handle', '%$remoteQ%')
          .neq('id', supabaseUserId!)
          .limit(25);
      final updated = Map<String, Person>.from(people);
      final matchedIds = <String>{};
      for (final row in rows) {
        final id = row['id'] as String;
        matchedIds.add(id);
        if (row['banned'] == true) _remoteBannedIds.add(id);
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
    // A cap on requests still waiting + a tiny cooldown so nobody can
    // carpet-bomb everybody they can find with Add Friend.
    if (!isAdmin && me.friendRequestsSent.length >= maxPendingFriendRequests) return;
    if (_tooSoon('friendRequest', 700)) return;
    if (selfBanned) return;
    me = me.copyWith(friendRequestsSent: [...me.friendRequestsSent, personId]);
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsReceived: [...them.friendRequestsReceived, 'me'])};
    }
    notifyListeners();
    _persist();
    final uid = supabaseUserId;
    if (signedIn && uid != null && _isRealPersonId(personId)) {
      _fireAndForgetInsert('friendships', {'requester_id': uid, 'addressee_id': personId});
    }
  }

  void cancelFriendRequest(String personId) {
    me = me.copyWith(friendRequestsSent: me.friendRequestsSent.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsReceived: them.friendRequestsReceived.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
    final uid = supabaseUserId;
    if (signedIn && uid != null && _isRealPersonId(personId)) {
      _fireAndForgetRemote(
        () => Supabase.instance.client.from('friendships').delete().eq('requester_id', uid).eq('addressee_id', personId),
      );
    }
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
    final uid = supabaseUserId;
    if (signedIn && uid != null && _isRealPersonId(personId)) {
      _fireAndForgetRemote(
        () => Supabase.instance.client
            .from('friendships')
            .update({'status': 'accepted'})
            .eq('requester_id', personId)
            .eq('addressee_id', uid),
      );
    }
  }

  void declineFriendRequest(String personId) {
    me = me.copyWith(friendRequestsReceived: me.friendRequestsReceived.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friendRequestsSent: them.friendRequestsSent.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
    final uid = supabaseUserId;
    if (signedIn && uid != null && _isRealPersonId(personId)) {
      _fireAndForgetRemote(
        () => Supabase.instance.client.from('friendships').delete().eq('requester_id', personId).eq('addressee_id', uid),
      );
    }
  }

  void removeFriend(String personId) {
    me = me.copyWith(friends: me.friends.where((id) => id != personId).toList());
    final them = people[personId];
    if (them != null) {
      people = {...people, personId: them.copyWith(friends: them.friends.where((id) => id != 'me').toList())};
    }
    notifyListeners();
    _persist();
    _fireAndForgetFriendshipRemove(personId);
  }

  // How often you're allowed to actually change your @handle — just
  // picking a handle for the first time (lastHandleChangeAt still null)
  // isn't rate-limited, only changing an existing one is.
  static const int _handleChangeCooldownMs = 15 * 24 * 60 * 60 * 1000;

  /// Returns null on success, or a user-facing error (still inside the
  /// 15-day cooldown) if the change didn't go through.
  static final RegExp _validHandle = RegExp(r'^[a-zA-Z0-9_]+$');

  Future<String?> setHandle(String handle) async {
    if (!signedIn) return 'Create an account to pick a username.';
    final trimmed = handle.trim();
    if (trimmed.isEmpty) return 'Enter a username.';
    if (trimmed == me.handle) return null; // unchanged — no-op, no cooldown hit
    if (trimmed.length > 20) return 'Usernames can be at most 20 characters.';
    if (!_validHandle.hasMatch(trimmed)) {
      return 'Usernames can only use letters, numbers, and underscores.';
    }
    // Admins can rename themselves as often as they like.
    final last = isAdmin ? null : me.lastHandleChangeAt;
    if (last != null) {
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsedMs < _handleChangeCooldownMs) {
        final daysLeft = ((_handleChangeCooldownMs - elapsedMs) / (24 * 60 * 60 * 1000)).ceil();
        return "You can change your username again in $daysLeft day${daysLeft == 1 ? '' : 's'}.";
      }
    }
    // For a real account the server is saved FIRST (handles are unique there,
    // and everyone else reads yours from the server) — so the new name is
    // only shown once it's really saved, and a "that name is taken" or a
    // failed save is reported instead of silently reverting later.
    final uid = supabaseUserId;
    if (signedIn && uid != null) {
      try {
        final saved = await _updateOwnProfile({'handle': trimmed});
        if (!saved) {
          return "Couldn't save that username — your account isn't set up on the server yet (run RUN_ALL.sql in Supabase).";
        }
      } on PostgrestException catch (e) {
        if (e.code == '23505') return 'That username is already taken — try another.';
        return "Couldn't save that username — check your connection and try again.";
      } catch (_) {
        return "Couldn't save that username — check your connection and try again.";
      }
    }
    me = me.copyWith(handle: trimmed, lastHandleChangeAt: DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
    _persist();
    return null;
  }

  /// Sets a profile photo captured with the in-app camera — FUNKY never
  /// uses a gallery/image picker, same rule as Stories (see
  /// CameraCaptureScreen).
  Future<String?> setProfilePhoto(String path) async {
    if (!signedIn) return 'Create an account to add a profile picture.';
    me = me.copyWith(photoPath: path);
    notifyListeners();
    _persist();
    return _uploadAvatar(path);
  }

  bool _avatarBackfillTried = false;

  /// Uploads your profile picture to the public avatars bucket and points
  /// your profile row at it, so everyone else sees it (their app can only
  /// show an image by URL — your local file path means nothing to them).
  Future<String?> _uploadAvatar(String path) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      if (await file.length() > 8 * 1024 * 1024) return 'That picture is too big — pick one under 8 MB.';
      final isPng = path.toLowerCase().endsWith('.png');
      final storagePath = '$uid/avatar.${isPng ? 'png' : 'jpg'}';
      final client = Supabase.instance.client;
      await client.storage.from('avatars').uploadBinary(
            storagePath,
            await file.readAsBytes(),
            fileOptions: FileOptions(upsert: true, contentType: isPng ? 'image/png' : 'image/jpeg'),
          );
      final url = client.storage.from('avatars').getPublicUrl(storagePath);
      // The same path is reused every time, so a changing query string is
      // what makes other devices actually refetch the new picture.
      final busted = '$url?v=${DateTime.now().millisecondsSinceEpoch}';
      final linked = await _updateOwnProfile({'avatar_url': busted});
      if (!linked) {
        return "Your picture uploaded but your profile couldn't be updated to show it — run RUN_ALL.sql in Supabase, then pick it again.";
      }
      return null;
    } catch (e) {
      // Your own device keeps showing the local file either way, but other
      // people can't see it until this works — so say why.
      return "Your picture saved on this phone but couldn't upload for other people — ${_friendlySendError(e)}";
    }
  }

  void setBio(String bio) {
    if (!signedIn) return; // no account yet — the profile screen asks them to create one
    // Defense-in-depth alongside the bio TextField's own `maxLength: 50` —
    // whatever actually gets saved/synced is capped here too.
    final capped = bio.length > 50 ? bio.substring(0, 50) : bio;
    me = me.copyWith(bio: capped);
    notifyListeners();
    _persist();
    if (signedIn && supabaseUserId != null) {
      _fireAndForgetUpdate('profiles', {'bio': capped}, supabaseUserId!);
    }
  }

  void setMove(String placeIdOrIn) {
    // Mashing the "I'm going" button can't spin up a pile of writes.
    if (_tooSoon('move', 600)) return;
    final isFirstPickTonight = me.move == null;
    var visited = me.placesVisited;
    if (placeIdOrIn != 'in' && !visited.contains(placeIdOrIn)) {
      visited = [...visited, placeIdOrIn];
    }
    me = me.copyWith(move: placeIdOrIn, placesVisited: visited);
    if (isFirstPickTonight) _award(3); // "vote where you're going"
    // The 🔥 going streak only counts voting for an actual place, not
    // "staying in".
    if (placeIdOrIn != 'in') _bumpMoveStreak();
    _recordNightActivity();
    notifyListeners();
    _persist();
  }

  /// Extends (or starts over) the daily "going" streak: voting for a place
  /// today after voting yesterday makes it +1; voting after missing a day
  /// (or ever) starts a fresh 1; voting again the same day does nothing.
  /// The displayed number also falls to 0 on its own once a day is missed —
  /// see effectiveMoveStreak in models.dart.
  void _bumpMoveStreak() {
    final today = sessionKey();
    if (me.moveStreakDay == today) return;
    final yesterday = sessionKey(DateTime.now().subtract(const Duration(days: 1)));
    final continuing = me.moveStreakDay == yesterday;
    me = me.copyWith(moveStreak: continuing ? me.moveStreak + 1 : 1, moveStreakDay: today);
  }

  void votePoll(String pollId, int optionIndex) {
    if (_tooSoon('votePoll', 300)) return;
    final pollIdx = polls.indexWhere((p) => p.id == pollId);
    if (pollIdx == -1 || optionIndex < 0 || optionIndex >= polls[pollIdx].options.length) return;
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
  /// A FUNKY Admin can add as many as they like.
  bool get canAddPlaceToday => isAdmin || !places.any((p) => p.by == 'me' && p.session == sessionKey());

  /// Same one-per-day rule as places, for polls (and the same Admin
  /// exemption).
  bool get canAddPollToday => isAdmin || !polls.any((p) => p.by == 'me' && p.session == sessionKey());

  // Lowercased, letters/digits-only — so "Sigma Chi", "sigma-chi!", and
  // "Sigma  Chi" all collapse to the same key before comparing names.
  String _normalizedPlaceName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// The existing place within the 25-mile radius (same radius
  /// [rankedPlacesFrom] uses — "nearby" always means the same thing) whose
  /// name looks like a duplicate of [name], or null if there isn't one.
  /// Lets the Add Place form warn before you even try to submit, and
  /// backstops [addPlace] itself in case something slips past that check.
  Place? similarNearbyPlace(String name, {LatLng? at}) {
    final target = _normalizedPlaceName(name);
    if (target.isEmpty) return null;
    final here = at ?? location ?? defaultLocation;
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
  String? lastPlaceError;

  /// [at] is where the pin goes (an address picked in the Add Place form);
  /// without it the pin drops at your current location.
  Future<Place?> addPlace(String name, PlaceKind kind, String address, {String? coverPhotoPath, LatLng? at}) async {
    lastPlaceError = null;
    if (selfBanned) {
      lastPlaceError = _bannedMessage;
      return null;
    }
    if (!canAddPlaceToday) return null;
    // Double-tap / rapid-fire guard — even an Admin can't create several in
    // the same instant.
    if (_tooSoon('addPlace', 3000)) return null;
    final cleanName = name.trim().length > maxPlaceNameLength ? name.trim().substring(0, maxPlaceNameLength) : name.trim();
    final cleanAddress = address.trim().length > maxPlaceAddressLength ? address.trim().substring(0, maxPlaceAddressLength) : address.trim();
    if (cleanName.isEmpty) return null;
    if (similarNearbyPlace(cleanName, at: at) != null) return null;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) {
      lastPlaceError = 'Log in to add a place.';
      return null;
    }
    final here = at ?? location ?? defaultLocation;
    // A place has to be in your own area (the 25 miles around you) — an
    // address picked from search can be anywhere, so check it.
    final myLocation = location;
    if (at != null && myLocation != null && !isAdmin && !near(myLocation, at)) {
      lastPlaceError = 'That address is more than ${rangeMiles.round()} miles from you — places have to be in your area.';
      return null;
    }
    // The cover photo goes up first (best-effort — a failed upload just
    // means the place is added without a shared photo) so its public URL
    // can ride along on the place row for everyone else to see.
    String? coverUrl;
    if (coverPhotoPath != null) coverUrl = await _uploadPlaceCover(uid, coverPhotoPath);
    // Places are shared, so this goes straight to the server and waits for
    // its real id (the same id everyone else will see) before showing up.
    final Place place;
    try {
      Future<List<Map<String, dynamic>>> insertPlace(bool withCover) {
        return _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('places').insert({
              'name': cleanName,
              'kind': kind.name,
              'lat': here.lat,
              'lng': here.lng,
              'address': cleanAddress,
              'by_uid': uid,
              // Only the admin's insert policy accepts a pre-verified place; for
              // everyone else this is just false.
              'admin_verified': isAdmin,
              if (withCover && coverUrl != null) 'cover_url': coverUrl,
            }).select());
      }

      List<Map<String, dynamic>> rows;
      try {
        rows = await insertPlace(true);
      } catch (e) {
        // The server hasn't got the cover_url column yet (phase 3 not run):
        // still add the place — just without a photo other people can see.
        final m = e.toString().toLowerCase();
        if (coverUrl != null && m.contains('cover_url')) {
          coverUrl = null;
          rows = await insertPlace(false);
        } else {
          rethrow;
        }
      }
      final built = _placeFromRow(rows.first);
      if (built == null) throw const FormatException('bad place row');
      place = Place(
        id: built.id,
        name: built.name,
        kind: built.kind,
        lat: built.lat,
        lng: built.lng,
        address: built.address,
        by: 'me',
        t: built.t,
        session: built.session,
        coverPhotoPath: coverPhotoPath,
        coverUrl: coverUrl,
      );
    } catch (e) {
      final why = _friendlySendError(e);
      lastPlaceError = why.startsWith('No connection') ? "Couldn't add that place — check your connection and try again." : "Couldn't add that place — $why";
      return null;
    }
    _remotePlaceIds.add(place.id);
    if (coverPhotoPath != null) _localPlaceCovers[place.id] = coverPhotoPath;
    places = [...places, place];
    // Whoever adds a place counts as its first real confirmation — it has
    // to earn the other 14 from real people. A FUNKY Admin's own places are
    // verified outright (and so also survive the nightly cleanup).
    placeConfirmations = {
      ...placeConfirmations,
      place.id: ['me'],
    };
    if (isAdmin) adminVerifiedPlaceIds = {...adminVerifiedPlaceIds, place.id};
    _fireAndForgetInsert('place_confirmations', {'place_id': place.id, 'user_id': uid});
    _award(10); // "add a missing venue"
    _recordNightActivity();
    notifyListeners();
    _persist();
    return place;
  }

  /// Uploads a place's cover photo to the public `place_covers` bucket and
  /// returns its URL, or null if it's missing, too big (8 MB), or the upload fails.
  Future<String?> _uploadPlaceCover(String uid, String path) async {
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() > 8 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      final storagePath = '$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final client = Supabase.instance.client;
      await client.storage.from('place_covers').uploadBinary(
            storagePath,
            bytes,
            fileOptions: const FileOptions(upsert: false, contentType: 'image/jpeg'),
          );
      return client.storage.from('place_covers').getPublicUrl(storagePath);
    } catch (_) {
      return null;
    }
  }

  /// Returns the new poll, or null if you've already added one today —
  /// see [canAddPollToday]. Callers should check that first so they can
  /// disable the "Post poll" button instead of only finding out after.
  String? lastPollError;

  Future<Poll?> addPoll(String q, List<String> options) async {
    lastPollError = null;
    if (selfBanned) {
      lastPollError = _bannedMessage;
      return null;
    }
    if (!canAddPollToday) {
      lastPollError = "You can only add one poll per day — check back after the 2 PM reset.";
      return null;
    }
    if (_tooSoon('addPoll', 3000)) {
      lastPollError = 'Hold on — your poll is already going up.';
      return null;
    }
    final cleanQ = q.trim().length > maxPollQuestionLength ? q.trim().substring(0, maxPollQuestionLength) : q.trim();
    final cleanOptions = options
        .map((o) => o.trim().length > maxPollOptionLength ? o.trim().substring(0, maxPollOptionLength) : o.trim())
        .where((o) => o.isNotEmpty)
        .take(maxPollOptions)
        .toList();
    if (cleanQ.isEmpty || cleanOptions.length < 2) {
      lastPollError = 'A poll needs a question and at least two options.';
      return null;
    }
    final uid = supabaseUserId;
    if (!signedIn || uid == null) {
      lastPollError = 'Log in to post a poll.';
      return null;
    }
    final here = location ?? defaultLocation;
    final Poll poll;
    try {
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('polls').insert({
            'q': cleanQ,
            'options': cleanOptions,
            'lat': here.lat,
            'lng': here.lng,
            'by_uid': uid,
          }).select());
      final built = _pollFromRow(rows.first);
      if (built == null) throw const FormatException('bad poll row');
      poll = built;
    } catch (e) {
      final why = _friendlySendError(e);
      lastPollError = why.startsWith('No connection') ? "Couldn't post that poll — check your connection and try again." : "Couldn't post that poll — $why";
      return null;
    }
    _remotePollIds.add(poll.id);
    polls = [...polls, poll];
    notifyListeners();
    _persist();
    return poll;
  }

  /// Returns null on success, or a user-facing error if you're still inside
  /// the cooldown (basic anti-spam — nothing fancier than "wait a moment").
  String? sendMessage(String room, String text, bool anon) {
    if (selfBanned) return _bannedMessage;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    final capped = text.length > _maxMessageLength ? text.substring(0, _maxMessageLength) : text;
    if (capped.trim().isEmpty) return null;
    final here = location;
    final message = ChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      room: room,
      uid: 'me',
      text: capped,
      anon: anon,
      status: room == 'main' && signedIn ? 'sending' : 'delivered',
      lat: room == 'main' ? here?.lat : null,
      lng: room == 'main' ? here?.lng : null,
    );
    messages = _capMessages([...messages, message]);
    _lastMessageAt = now;
    notifyListeners();
    _persist();
    if (room == 'main' && signedIn && supabaseUserId != null) {
      unawaited(_sendLiveChatRemote(message));
    }
    return null;
  }

  /// Posts a Live Chat message to the shared `chat_messages` table. The
  /// message is already showing locally under a temporary id; on success it
  /// swaps to the server's real id (so the realtime echo of its own insert
  /// is recognised and not shown twice), on failure it's marked 'failed'.
  Future<void> _sendLiveChatRemote(ChatMessage local) async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('chat_messages').insert({
            // Anonymous messages carry NO sender at all (see the SQL) — the
            // server keeps the real author in an admin-only table.
            'sender_id': local.anon ? null : uid,
            'text': local.text,
            'anon': local.anon,
            'lat': local.lat,
            'lng': local.lng,
          }).select());
      final serverId = rows.first['id'] as String;
      _remoteChatIds.add(serverId);
      messages = messages
          .where((m) => m.id != serverId)
          .map((m) => m.id == local.id ? m.copyWith(id: serverId, status: 'sent') : m)
          .toList();
    } catch (e) {
      _sendErrors[local.id] = _friendlySendError(e);
      messages = messages.map((m) => m.id == local.id ? m.copyWith(status: 'failed') : m).toList();
    }
    notifyListeners();
    _persist();
  }

  // Why a message failed to send, keyed by its (temporary) id — shown under
  // "Not sent" so a failure says what's actually wrong.
  final Map<String, String> _sendErrors = {};
  String? sendErrorFor(String messageId) => _sendErrors[messageId];

  /// True when an insert failed because your account has no row in the
  /// server's `profiles` table yet (a foreign-key error) — fixable by
  /// [_ensureOwnProfile].
  bool _isMissingProfileError(Object e) {
    if (e is! PostgrestException) return false;
    final m = '${e.code ?? ''} ${e.message} ${e.details}'.toLowerCase();
    return m.contains('23503') && (m.contains('profiles') || m.contains('sender_id') || m.contains('by_uid') || m.contains('user_id'));
  }

  /// Asks the server to create your profile row if it's missing (the
  /// `ensure_my_profile` function from phase 6). Returns false if that
  /// function isn't installed or the call failed.
  Future<bool> _ensureOwnProfile() async {
    try {
      await Supabase.instance.client.rpc('ensure_my_profile');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Runs a server write; if it fails only because your profile row is
  /// missing, creates that row and tries once more.
  Future<T> _withProfileRepair<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      if (_isMissingProfileError(e) && await _ensureOwnProfile()) return await op();
      rethrow;
    }
  }

  /// Updates your own profile row and reports whether a row really changed.
  /// (The server answers "success" with zero rows when it blocks an update
  /// or the row doesn't exist, so success alone proves nothing.) A missing
  /// row is created and the update tried again.
  Future<bool> _updateOwnProfile(Map<String, dynamic> data) async {
    final uid = supabaseUserId;
    if (uid == null) return false;
    final client = Supabase.instance.client;
    var rows = await client.from('profiles').update(data).eq('id', uid).select('id');
    if (rows.isNotEmpty) return true;
    if (!await _ensureOwnProfile()) return false;
    rows = await client.from('profiles').update(data).eq('id', uid).select('id');
    return rows.isNotEmpty;
  }

  String _friendlySendError(Object e) {
    final text = e is PostgrestException ? '${e.code ?? ''} ${e.message}' : e.toString();
    final lower = text.toLowerCase();
    if (lower.contains('pgrst205') || lower.contains('schema cache') || lower.contains('does not exist') || lower.contains('42p01')) {
      return "The server isn't set up for this yet (run the latest SQL files in Supabase).";
    }
    if (lower.contains('rate limit')) return 'Slow down — you are sending too fast.';
    if (lower.contains('23503') && lower.contains('profiles')) {
      return "Your account isn't fully set up on the server (run RUN_ALL.sql in Supabase).";
    }
    if (lower.contains('row-level security') || lower.contains('42501') || lower.contains('permission denied')) {
      return 'The server refused it (permissions) — try logging out and back in.';
    }
    if (lower.contains('socket') || lower.contains('clientexception') || lower.contains('timeout') || lower.contains('host lookup')) {
      return 'No connection — check your internet.';
    }
    final trimmed = text.trim();
    return trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
  }

  /// Tap-to-retry on a live-chat message that shows "Not sent".
  void retryChatMessage(String messageId) {
    if (_tooSoon('chatRetry', 1500)) return;
    final i = messages.indexWhere((m) => m.id == messageId && m.status == 'failed' && m.uid == 'me' && m.room == 'main');
    if (i == -1 || !signedIn || supabaseUserId == null) return;
    _sendErrors.remove(messageId);
    final retrying = messages[i].copyWith(status: 'sending');
    messages = [...messages]..[i] = retrying;
    notifyListeners();
    unawaited(_sendLiveChatRemote(retrying));
  }

  /// Keeps only the newest [maxMessagesKept] messages in memory so a chat
  /// that stays open all night can't grow without bound.
  List<ChatMessage> _capMessages(List<ChatMessage> list) {
    if (list.length <= maxMessagesKept) return list;
    return list.sublist(list.length - maxMessagesKept);
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
  Future<String?> sendDirectMessage(String toPersonId, String text, {String? mediaPath, String? mediaType, bool skipCooldown = false}) async {
    if (selfBanned) return _bannedMessage;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (!skipCooldown && last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    final capped = text.length > _maxMessageLength ? text.substring(0, _maxMessageLength) : text;
    final mp = mediaPath;
    final mt = mediaType;
    final hasMedia = mp != null && mt != null;
    if (capped.trim().isEmpty && !hasMedia) return null;
    if (hasMedia) {
      if (!skipCooldown && _tooSoon('dmMedia', 5000)) return 'Slow down — one snap every few seconds.';
      try {
        final bytes = await File(mp!).length();
        if (mt == 'video' && bytes > maxDmVideoBytes) {
          return 'That video is too big — keep it under ${maxDmVideoBytes ~/ (1024 * 1024)} MB.';
        }
        if (mt != 'video' && bytes > maxDmImageBytes) {
          return 'That photo is too big — keep it under ${maxDmImageBytes ~/ (1024 * 1024)} MB.';
        }
      } catch (_) {
        return "Couldn't read that file.";
      }
    }
    final remote = signedIn && supabaseUserId != null && _remotePersonIds.contains(toPersonId);
    final local = ChatMessage(
      id: 'dm_${DateTime.now().microsecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      room: dmRoomId('me', toPersonId),
      uid: 'me',
      text: capped,
      anon: false,
      status: remote ? 'sending' : 'delivered',
      mediaType: hasMedia ? mt : null,
      mediaPath: hasMedia ? mp : null,
    );
    messages = _capMessages([...messages, local]);
    _lastMessageAt = now;
    notifyListeners();
    _persist();
    if (remote) unawaited(_deliverDirectMessage(local, toPersonId));
    return null;
  }

  /// Uploads a DM's photo/video (if any), inserts the `messages` row, and
  /// swaps the optimistic local message over to the server's id with the
  /// status 'delivered' — or 'failed' (tap to retry) if anything throws.
  Future<void> _deliverDirectMessage(ChatMessage local, String toPersonId) async {
    final uid = supabaseUserId;
    if (uid == null) {
      _setMessageStatus(local.id, 'failed');
      return;
    }
    try {
      final client = Supabase.instance.client;
      String? storagePath;
      final localFile = local.mediaPath;
      if (localFile != null) {
        final file = File(localFile);
        final bytes = await file.readAsBytes();
        final isVideo = local.mediaType == 'video';
        final dot = localFile.lastIndexOf('.');
        var ext = dot == -1 ? (isVideo ? 'mp4' : 'jpg') : localFile.substring(dot + 1).toLowerCase();
        if (ext.length > 5) ext = isVideo ? 'mp4' : 'jpg';
        storagePath = '$uid/${local.t}_${local.id.hashCode.abs()}.$ext';
        await client.storage.from('dm_media').uploadBinary(
              storagePath,
              bytes,
              fileOptions: FileOptions(
                upsert: true,
                contentType: isVideo ? (ext == 'mov' ? 'video/quicktime' : 'video/mp4') : (ext == 'png' ? 'image/png' : 'image/jpeg'),
              ),
            );
      }
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => client.from('messages').insert({
            'sender_id': uid,
            'recipient_id': toPersonId,
            'text': local.text,
            if (storagePath != null) 'media_path': storagePath,
            if (storagePath != null) 'media_type': local.mediaType,
          }).select());
      final serverId = rows.first['id'] as String;
      _remoteMessageIds.add(serverId);
      messages = messages
          .where((m) => m.id != serverId)
          .map((m) => m.id == local.id ? m.copyWith(id: serverId, status: 'delivered') : m)
          .toList();
    } catch (e) {
      _sendErrors[local.id] = _friendlySendError(e);
      messages = messages.map((m) => m.id == local.id ? m.copyWith(status: 'failed') : m).toList();
    }
    notifyListeners();
    _persist();
  }

  void _setMessageStatus(String id, String status) {
    messages = messages.map((m) => m.id == id ? m.copyWith(status: status) : m).toList();
    notifyListeners();
    _persist();
  }

  /// Tap-to-retry on a DM that shows "Not sent".
  void retryDirectMessage(String messageId) {
    if (_tooSoon('dmRetry', 1500)) return;
    final i = messages.indexWhere((m) => m.id == messageId && m.status == 'failed' && m.uid == 'me');
    if (i == -1) return;
    final m = messages[i];
    if (m.room.startsWith('grp_')) {
      _setMessageStatus(m.id, 'sending');
      unawaited(_deliverGroupMessage(m.copyWith(status: 'sending'), m.room.substring(4)));
      return;
    }
    if (!m.room.startsWith('dm_')) return;
    final ids = m.room.substring(3).split('_');
    final other = ids.length == 2 ? (ids[0] == 'me' ? ids[1] : ids[0]) : null;
    if (other == null || !_remotePersonIds.contains(other)) return;
    _setMessageStatus(m.id, 'sending');
    unawaited(_deliverDirectMessage(m.copyWith(status: 'sending'), other));
  }

  // Newest incoming message time we've already told the server we've seen,
  // per person — so opening a thread doesn't re-send the same update.
  final Map<String, int> _seenMarkedAt = {};

  /// Called when a DM thread is open (and when new messages land while it
  /// is) — stamps `read_at` on everything they sent you so THEIR screen
  /// flips from "Delivered" to "Seen".
  void markDmSeen(String personId) {
    final uid = supabaseUserId;
    if (uid == null || !signedIn || !_remotePersonIds.contains(personId)) return;
    final room = dmRoomId('me', personId);
    var latest = 0;
    for (final m in messages) {
      if (m.room == room && m.uid == personId && m.t > latest) latest = m.t;
    }
    if (latest == 0 || (_seenMarkedAt[personId] ?? 0) >= latest) return;
    _seenMarkedAt[personId] = latest;
    unawaited(() async {
      try {
        await Supabase.instance.client
            .from('messages')
            .update({'read_at': DateTime.now().toUtc().toIso8601String()})
            .eq('sender_id', personId)
            .eq('recipient_id', uid)
            .filter('read_at', 'is', null);
      } catch (_) {
        _seenMarkedAt.remove(personId);
      }
    }());
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
    // The UI checks storyBlockReason() first and shows why; this is the
    // backstop so nothing that skips that check can post past the limits.
    if (storyBlockReason() != null) return;
    _lastActionAt['story'] = DateTime.now().millisecondsSinceEpoch;
    if (text != null && text.length > maxStoryTextLength) text = text.substring(0, maxStoryTextLength);
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
          final mediaFile = File(localMediaFile);
          // Too big to upload (or somehow gone) — drop to the local-only post
          // below instead of trying to push it through and risking a crash.
          if (await mediaFile.length() > maxStoryUploadBytes) throw const FileSystemException('Story media too large to upload');
          final bytes = await mediaFile.readAsBytes();
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
    if (_tooSoon('reaction', 250)) return;
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
    // Live-chat messages that exist on the server share their reactions with
    // everyone: your reaction is upserted (one per person per message) or,
    // when you tapped the same emoji again, removed.
    final uid = supabaseUserId;
    if (signedIn && uid != null && _remoteChatIds.contains(messageId)) {
      if (alreadyThisEmoji) {
        _fireAndForgetRemote(
          () => Supabase.instance.client.from('chat_reactions').delete().eq('message_id', messageId).eq('user_id', uid),
        );
      } else {
        _fireAndForgetRemote(
          () => Supabase.instance.client.from('chat_reactions').upsert({'message_id': messageId, 'user_id': uid, 'emoji': emoji}),
        );
      }
    }
  }

  /// Sets (or, with a null [emoji], clears) one person's reaction on a
  /// message — the single place remote reaction changes are applied.
  /// Returns true if anything changed.
  bool _applyReactionChange(String messageId, String userId, String? emoji) {
    final i = messages.indexWhere((m) => m.id == messageId);
    if (i == -1) return false;
    final who = userId == supabaseUserId ? 'me' : userId;
    final current = messages[i].reactions;
    final next = <String, List<String>>{};
    for (final entry in current.entries) {
      final others = entry.value.where((u) => u != who).toList();
      if (others.isNotEmpty) next[entry.key] = others;
    }
    if (emoji != null && emoji.isNotEmpty) next[emoji] = [...(next[emoji] ?? const []), who];
    final same = next.length == current.length &&
        next.entries.every((e) {
          final c = current[e.key];
          return c != null && c.length == e.value.length && c.toSet().containsAll(e.value);
        });
    if (same) return false;
    messages = [...messages]..[i] = messages[i].copyWith(reactions: next);
    return true;
  }

  void _onRemoteReactionChange(Map<String, dynamic> row, {required bool removed}) {
    final messageId = row['message_id'] as String?;
    final userId = row['user_id'] as String?;
    if (messageId == null || userId == null) return;
    final emoji = removed ? null : row['emoji'] as String?;
    if (_applyReactionChange(messageId, userId, emoji)) notifyListeners();
  }

  /// Pulls tonight's live-chat reactions and rebuilds each remote message's
  /// reaction list from them (so a reaction removed elsewhere disappears).
  Future<void> _fetchRemoteReactions() async {
    if (supabaseUserId == null) return;
    try {
      final cutoff = DateTime.fromMillisecondsSinceEpoch(_sessionStartMs()).toUtc().toIso8601String();
      final rows = await Supabase.instance.client.from('chat_reactions').select().gte('created_at', cutoff).limit(3000);
      final byMessage = <String, Map<String, List<String>>>{};
      for (final row in rows) {
        final mid = row['message_id'] as String?;
        final u = row['user_id'] as String?;
        final e = row['emoji'] as String?;
        if (mid == null || u == null || e == null) continue;
        ((byMessage[mid] ??= {})[e] ??= []).add(u == supabaseUserId ? 'me' : u);
      }
      var changed = false;
      messages = messages.map((m) {
        if (!_remoteChatIds.contains(m.id)) return m;
        final remote = byMessage[m.id] ?? const <String, List<String>>{};
        if (remote.isEmpty && m.reactions.isEmpty) return m;
        changed = true;
        return m.copyWith(reactions: remote);
      }).toList();
      if (changed) notifyListeners();
    } catch (_) {
      // Offline — realtime catches up.
    }
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
    _lastActionAt['report'] = DateTime.now().millisecondsSinceEpoch;
    final trimmedDetail = detail == null ? null : (detail.length > maxReportDetailLength ? detail.substring(0, maxReportDetailLength) : detail);
    final report = PlaceReport(
      id: 'report_${DateTime.now().millisecondsSinceEpoch}',
      placeId: placeId,
      kind: kind,
      detail: trimmedDetail,
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
    // Shows up instantly under a temporary id; the server's real id (the one
    // everyone else's confirmations attach to) swaps in once it's saved.
    if (signedIn && supabaseUserId != null && _remotePlaceIds.contains(placeId)) {
      unawaited(_saveReportRemote(report));
    }
    return report;
  }

  Future<void> _saveReportRemote(PlaceReport local) async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await Supabase.instance.client.from('place_reports').insert({
        'place_id': local.placeId,
        'kind': local.kind.name,
        'detail': local.detail,
        'reporter_id': uid,
      }).select();
      final serverId = rows.first['id'] as String;
      _remoteReportIds.add(serverId);
      placeReports = placeReports
          .where((r) => r.id != serverId)
          .map((r) => r.id == local.id ? PlaceReport(
                id: serverId,
                placeId: r.placeId,
                kind: r.kind,
                detail: r.detail,
                t: r.t,
                reporterId: r.reporterId,
                confirmedBy: r.confirmedBy,
              ) : r)
          .toList();
      notifyListeners();
      _persist();
    } catch (_) {
      // The report stays on this device only — a failed save (rate limit,
      // offline) just doesn't reach anyone else.
    }
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
    final uid = supabaseUserId;
    if (signedIn && uid != null && _remoteReportIds.contains(reportId)) {
      _fireAndForgetInsert('report_confirmations', {'report_id': reportId, 'user_id': uid});
    }
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
    if (_remoteReportIds.remove(reportId)) {
      _fireAndForgetRemote(() => Supabase.instance.client.from('place_reports').delete().eq('id', reportId));
    }
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
  /// Where the email-confirmation link sends you — the app's own URL scheme.
  /// Must also be listed under Authentication → URL Configuration → Redirect
  /// URLs in the Supabase dashboard.
  static const String authRedirectUrl = 'com.funkyapp.funky://login-callback/';

  StreamSubscription<AuthState>? _authSub;

  /// Picks up a sign-in that happens OUTSIDE the login form — tapping the
  /// confirmation link in the email opens the app already signed in, and
  /// this is what makes the app notice.
  void _listenForAuthChanges() {
    _authSub?.cancel();
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final s = data.session;
      if (data.event == AuthChangeEvent.signedIn && s != null && !signedIn) {
        accountEmail = s.user.email;
        supabaseUserId = s.user.id;
        signedIn = true;
        notifyListeners();
        _persist();
        _startRemoteSync();
      }
    });
  }

  Future<String?> signUp(String email, String password) async {
    final emailError = validateEmail(email);
    if (emailError != null) return emailError;
    final pwError = validatePassword(password);
    if (pwError != null) return pwError;
    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: email.trim(),
        password: password,
        // The confirmation link opens THIS app (see CFBundleURLTypes in
        // Info.plist) instead of Supabase's default "localhost" page.
        emailRedirectTo: authRedirectUrl,
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
    // Stop this phone's pushes for the account that's leaving (while we're
    // still allowed to), so the next person to log in here doesn't get them.
    await _unregisterPush();
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
  RealtimeChannel? _placesChannel;
  RealtimeChannel? _placeConfirmationsChannel;
  RealtimeChannel? _placeRatingsChannel;
  RealtimeChannel? _photoSuggestionsChannel;
  RealtimeChannel? _profileReportsChannel;
  RealtimeChannel? _groupMessagesChannel;
  RealtimeChannel? _groupsChannel;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _chatReactionsChannel;
  RealtimeChannel? _friendshipsChannel;
  RealtimeChannel? _profilesChannel;
  RealtimeChannel? _pollsChannel;
  RealtimeChannel? _pollVotesChannel;
  RealtimeChannel? _reportsChannel;
  RealtimeChannel? _reportConfirmationsChannel;

  // Every story/message/person id that came from the real backend, tracked
  // just so signOut (_clearRemoteData) can cleanly drop them again.
  final Set<String> _remoteStoryIds = {};
  final Set<String> _remoteMessageIds = {};
  final Set<String> _remotePersonIds = {};
  final Set<String> _remotePlaceIds = {};
  final Set<String> _remoteChatIds = {};
  final Set<String> _remotePollIds = {};
  final Set<String> _remoteReportIds = {};
  // pollId -> (voter id, or 'me') -> option index, for polls from the server.
  final Map<String, Map<String, int>> _remotePollVotes = {};

  void _startRemoteSync() {
    final uid = supabaseUserId;
    if (uid == null) return;
    _stopRemoteSync();
    _lastFullRefresh = DateTime.now();
    _resetLocalIfDifferentAccount(uid);
    unawaited(_fetchRemoteProfiles());
    unawaited(_fetchRemoteFriendships());
    unawaited(_fetchRemotePlaces(purge: true));
    unawaited(_fetchPlaceRatings());
    unawaited(_fetchPhotoSuggestions());
    unawaited(_fetchProfileReports());
    unawaited(_fetchGroups());
    unawaited(_fetchRemoteChat());
    unawaited(_fetchRemotePolls());
    unawaited(_fetchRemoteReports());
    unawaited(_fetchRemoteStories());
    unawaited(_fetchRemoteMessages());
    unawaited(_fetchNotifications());
    unawaited(_fetchNotifPrefs());
    unawaited(_registerPush());

    final client = Supabase.instance.client;
    _notificationsChannel = client.channel('public:notifications:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'notifications',
        callback: (payload) => _onRemoteNotification(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'notifications',
        callback: (payload) => _onRemoteNotification(payload.newRecord),
      )
      ..subscribe();

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

    _groupMessagesChannel = client.channel('public:group_messages:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'group_messages',
        callback: (payload) => _onRemoteGroupMessageInsert(payload.newRecord),
      )
      ..subscribe();

    _groupsChannel = client.channel('public:groups:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_members',
        callback: (_) => _scheduleGroupsRefresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_chats',
        callback: (_) => _scheduleGroupsRefresh(),
      )
      ..subscribe();

    _messagesChannel = client.channel('public:messages:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'messages',
        callback: (payload) => _onRemoteMessageInsert(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'messages',
        callback: (payload) => _onRemoteMessageUpdate(payload.newRecord),
      )
      ..subscribe();

    // Places and their confirmations change rarely and in small ways, so
    // any change just triggers a (debounced) re-fetch of both rather than
    // trying to patch the local lists event by event.
    _placesChannel = client.channel('public:places:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'places',
        callback: (_) => _schedulePlacesRefresh(),
      )
      ..subscribe();

    _placeConfirmationsChannel = client.channel('public:place_confirmations:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'place_confirmations',
        callback: (_) => _schedulePlacesRefresh(),
      )
      ..subscribe();

    _placeRatingsChannel = client.channel('public:place_ratings:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'place_ratings',
        callback: (_) => _scheduleRatingsRefresh(),
      )
      ..subscribe();

    _photoSuggestionsChannel = client.channel('public:place_photo_suggestions:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'place_photo_suggestions',
        callback: (_) => unawaited(_fetchPhotoSuggestions()),
      )
      ..subscribe();

    _profileReportsChannel = client.channel('public:profile_reports:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'profile_reports',
        callback: (_) => unawaited(_fetchProfileReports()),
      )
      ..subscribe();

    _chatChannel = client.channel('public:chat_messages:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'chat_messages',
        callback: (payload) => _onRemoteChatInsert(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'chat_messages',
        callback: (payload) => _onRemoteChatDelete(payload.oldRecord),
      )
      ..subscribe();

    _chatReactionsChannel = client.channel('public:chat_reactions:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'chat_reactions',
        callback: (payload) => _onRemoteReactionChange(payload.newRecord, removed: false),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'chat_reactions',
        callback: (payload) => _onRemoteReactionChange(payload.newRecord, removed: false),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'chat_reactions',
        callback: (payload) => _onRemoteReactionChange(payload.oldRecord, removed: true),
      )
      ..subscribe();

    _pollsChannel = client.channel('public:polls:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'polls',
        callback: (_) => _schedulePollsRefresh(),
      )
      ..subscribe();

    _pollVotesChannel = client.channel('public:poll_votes:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'poll_votes',
        callback: (_) => _schedulePollsRefresh(),
      )
      ..subscribe();

    _reportsChannel = client.channel('public:place_reports:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'place_reports',
        callback: (_) => _scheduleReportsRefresh(),
      )
      ..subscribe();

    _reportConfirmationsChannel = client.channel('public:report_confirmations:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'report_confirmations',
        callback: (_) => _scheduleReportsRefresh(),
      )
      ..subscribe();

    // RLS already limits this to your own friendships — any change
    // (a new request, an accept, an unfriend) re-reads the whole set.
    _friendshipsChannel = client.channel('public:friendships:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'friendships',
        callback: (_) => unawaited(_fetchRemoteFriendships()),
      )
      ..subscribe();

    // Profile changes: someone's "going" pick, points, name style, a ban,
    // an admin points gift to YOU — all arrive as updates to that row.
    _profilesChannel = client.channel('public:profiles:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'profiles',
        callback: (payload) => _applyProfileRow(payload.newRecord),
      )
      ..subscribe();
  }

  void _stopRemoteSync() {
    final client = Supabase.instance.client;
    for (final channel in [
      _storiesChannel,
      _storyViewsChannel,
      _storyLikesChannel,
      _messagesChannel,
      _placesChannel,
      _placeConfirmationsChannel,
      _placeRatingsChannel,
      _photoSuggestionsChannel,
      _profileReportsChannel,
      _groupMessagesChannel,
      _groupsChannel,
      _chatChannel,
      _chatReactionsChannel,
      _friendshipsChannel,
      _profilesChannel,
      _pollsChannel,
      _pollVotesChannel,
      _reportsChannel,
      _reportConfirmationsChannel,
      _notificationsChannel,
    ]) {
      if (channel != null) client.removeChannel(channel);
    }
    _storiesChannel = null;
    _storyViewsChannel = null;
    _storyLikesChannel = null;
    _messagesChannel = null;
    _placesChannel = null;
    _placeConfirmationsChannel = null;
    _placeRatingsChannel = null;
    _photoSuggestionsChannel = null;
    _profileReportsChannel = null;
    _groupMessagesChannel = null;
    _groupsChannel = null;
    _chatChannel = null;
    _chatReactionsChannel = null;
    _friendshipsChannel = null;
    _profilesChannel = null;
    _pollsChannel = null;
    _pollVotesChannel = null;
    _reportsChannel = null;
    _reportConfirmationsChannel = null;
    _notificationsChannel = null;
    _placesRefreshTimer?.cancel();
    _placesRefreshTimer = null;
    _pollsRefreshTimer?.cancel();
    _pollsRefreshTimer = null;
    _ratingsRefreshTimer?.cancel();
    _ratingsRefreshTimer = null;
    _groupsRefreshTimer?.cancel();
    _groupsRefreshTimer = null;
    _reportsRefreshTimer?.cancel();
    _reportsRefreshTimer = null;
  }

  void _clearRemoteData() {
    notifications = [];
    placeRatings = {};
    pendingPhotoSuggestions = [];
    myPendingPhotoPlaces = {};
    openProfileReports = [];
    groups = [];
    notifPrefs = const NotificationPrefs();
    _syncedLocation = null;
    _syncedLocationAt = null;
    unawaited(PushService.setBadge(0));
    stories = stories.where((s) => !_remoteStoryIds.contains(s.id)).toList();
    messages = messages.where((m) => !_remoteMessageIds.contains(m.id) && !_remoteChatIds.contains(m.id)).toList();
    people = {for (final entry in people.entries) if (!_remotePersonIds.contains(entry.key)) entry.key: entry.value};
    places = places.where((p) => !_remotePlaceIds.contains(p.id)).toList();
    placeConfirmations = {for (final e in placeConfirmations.entries) if (!_remotePlaceIds.contains(e.key)) e.key: e.value};
    adminVerifiedPlaceIds = adminVerifiedPlaceIds.where((id) => !_remotePlaceIds.contains(id)).toSet();
    polls = polls.where((p) => !_remotePollIds.contains(p.id)).toList();
    placeReports = placeReports.where((r) => !_remoteReportIds.contains(r.id)).toList();
    me = me.copyWith(friends: const [], friendRequestsSent: const [], friendRequestsReceived: const []);
    _remotePollIds.clear();
    _remoteReportIds.clear();
    _remotePollVotes.clear();
    _remoteStoryIds.clear();
    _remoteMessageIds.clear();
    _seenMarkedAt.clear();
    _remotePersonIds.clear();
    _remotePlaceIds.clear();
    _remoteChatIds.clear();
    _remoteBannedIds.clear();
    selfBanned = false;
    _remoteAdmin = false;
    _avatarBackfillTried = false;
    _profileSynced = false;
    _lastProfilePush = null;
  }

  /// A shared phone: if a DIFFERENT account signs in than the one this
  /// device's saved progress belongs to, start that account from a clean
  /// profile instead of handing it the previous person's points, name
  /// styling, streak, and Memories. The very first sign-in on a device
  /// (nothing recorded yet) keeps whatever progress is already here.
  void _resetLocalIfDifferentAccount(String uid) {
    final previous = _lastUserId;
    _lastUserId = uid;
    if (previous == null || previous == uid) return;
    me = freshMe();
    stories = stories.where((s) => s.uid != 'me').toList();
    messages = messages.where((m) => m.uid != 'me').toList();
    placeReports = placeReports.where((r) => r.reporterId != 'me').toList();
    polls = polls.where((p) => p.by != 'me').toList();
    placeConfirmations = {for (final e in placeConfirmations.entries) e.key: e.value.where((id) => id != 'me').toList()};
    _appliedBonus = 0;
    _localPlaceCovers.clear();
    notifyListeners();
  }

  // The Supabase user id this device's saved progress belongs to — persisted
  // so _resetLocalIfDifferentAccount can tell a new account from a re-login.
  String? _lastUserId;

  // The total admin-gifted bonus points currently folded into me.points —
  // tracked separately so a new gift (or a fresh device) can be applied as
  // an exact delta, and so only EARNED points (total minus this) are ever
  // pushed up to profiles.points. Persisted.
  int _appliedBonus = 0;
  bool _profileSynced = false;
  String? _lastProfilePush;

  // Place cover photos only exist as files on the device that took them (no
  // upload yet) — this remembers placeId -> local path so a re-fetch from
  // the backend doesn't lose your own cover photo. Persisted.
  final Map<String, String> _localPlaceCovers = {};

  Timer? _placesRefreshTimer;
  void _schedulePlacesRefresh() {
    _placesRefreshTimer?.cancel();
    _placesRefreshTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_fetchRemotePlaces()));
  }

  /// Runs a Supabase call without waiting on it — errors are swallowed on
  /// purpose (the local copy already updated; the server catches up on the
  /// next successful sync).
  void _fireAndForgetRemote(Future<dynamic> Function() op) {
    unawaited(() async {
      try {
        await op();
      } catch (_) {}
    }());
  }

  void _fireAndForgetRpc(String fn, Map<String, dynamic> params) {
    _fireAndForgetRemote(() => Supabase.instance.client.rpc(fn, params: params));
  }

  // --- Profile sync ----------------------------------------------------

  Future<void> _fetchRemoteProfiles({bool othersOnly = false}) async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final client = Supabase.instance.client;
      // Your own row first (that's what unlocks pushing your state up),
      // then everyone who's currently "going" somewhere tonight so the
      // going counts are real from the first frame.
      var mine = await client.from('profiles').select().eq('id', uid);
      if (mine.isEmpty && await _ensureOwnProfile()) {
        // Your account had no profile row (so nothing you did could stick) —
        // it has one now.
        mine = await client.from('profiles').select().eq('id', uid);
      }
      if (!othersOnly) {
        for (final row in mine) {
          _applyProfileRow(row);
        }
      }
      final tonight = await client.from('profiles').select().eq('move_session', sessionKey()).limit(1000);
      for (final row in tonight) {
        _applyProfileRow(row);
      }
      // Everyone the admin has banned, so their stuff is hidden here too.
      final banned = await client.from('profiles').select().eq('banned', true).limit(500);
      for (final row in banned) {
        _applyProfileRow(row);
      }
    } catch (_) {
      // Offline — the realtime channel / next sync catches up.
    }
  }

  /// Folds one `profiles` row into local state: your own row reconciles
  /// points/streak/style/ban status; anyone else's refreshes their Person
  /// (avatar, going-to, name style, points, ban, admin flag).
  void _applyProfileRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null) return;
    if (id == supabaseUserId) {
      _applyOwnProfileRow(row);
      return;
    }
    final banned = row['banned'] as bool? ?? false;
    if (banned) {
      _remoteBannedIds.add(id);
    } else {
      _remoteBannedIds.remove(id);
    }
    _remotePersonIds.add(id);
    people = {...people, id: _personFromProfileRow(row)};
    notifyListeners();
  }

  // The placeholder handle a brand-new account gets before it picks/gets a
  // real one (see handle_new_user in the SQL).
  static final RegExp _autoHandle = RegExp(r'^funky_[0-9a-f]{8}$');
  bool _assigningHandle = false;
  static const List<String> _handleAdjectives = [
    'Neon', 'Funky', 'Wild', 'Midnight', 'Electric', 'Cosmic', 'Sunny', 'Velvet',
    'Turbo', 'Disco', 'Glitter', 'Lucky', 'Spicy', 'Groovy', 'Hyper', 'Chill',
  ];
  static const List<String> _handleNouns = [
    'Fox', 'Panda', 'Tiger', 'Comet', 'Falcon', 'Otter', 'Raven', 'Llama',
    'Gecko', 'Moose', 'Wolf', 'Koala', 'Dragon', 'Pixel', 'Rocket', 'Taco',
  ];

  String _randomHandle() {
    final r = math.Random();
    return '${_handleAdjectives[r.nextInt(_handleAdjectives.length)]}'
        '${_handleNouns[r.nextInt(_handleNouns.length)]}'
        '${100 + r.nextInt(900)}';
  }

  /// Gives this account a random username like "NeonFox482" — written to the
  /// server first (handles are unique there, so a collision just tries a
  /// different one) and only then shown locally.
  Future<void> _assignRandomHandle() async {
    final uid = supabaseUserId;
    if (uid == null || _assigningHandle) return;
    _assigningHandle = true;
    try {
      for (var i = 0; i < 8; i++) {
        final h = _randomHandle();
        try {
          final saved = await _updateOwnProfile({'handle': h});
          if (!saved) return; // no profile row and it couldn't be created — the checker explains why
          me = me.copyWith(handle: h, clearLastHandleChange: true);
          notifyListeners();
          _persist();
          return;
        } on PostgrestException catch (e) {
          if (e.code != '23505') return; // anything but "that name is taken"
        }
      }
    } catch (_) {
      // Offline — it just tries again the next time the profile loads.
    } finally {
      _assigningHandle = false;
    }
  }

  void _applyOwnProfileRow(Map<String, dynamic> row) {
    selfBanned = row['banned'] as bool? ?? false;
    final wasRemoteAdmin = _remoteAdmin;
    _remoteAdmin = row['is_admin'] as bool? ?? false;
    if (_remoteAdmin && !wasRemoteAdmin) {
      // Just learned this account is an admin — pull in what's waiting.
      unawaited(_fetchProfileReports());
      unawaited(_fetchPhotoSuggestions());
    }
    final remoteEarned = (row['points'] as num?)?.toInt() ?? 0;
    final bonus = (row['bonus_points'] as num?)?.toInt() ?? 0;
    final localEarned = me.points - _appliedBonus;
    final earned = localEarned > remoteEarned ? localEarned : remoteEarned;
    var next = me;
    final total = earned + bonus < 0 ? 0 : earned + bonus;
    if (total != me.points) next = next.copyWith(points: total);
    _appliedBonus = bonus;

    // A device that's never set a handle/bio/photo/style adopts what the
    // account already has on the server (a second phone, a reinstall).
    final serverHandle = row['handle'] as String?;
    if (serverHandle != null && serverHandle.isNotEmpty) {
      if (_autoHandle.hasMatch(serverHandle)) {
        // A brand-new account still wearing the placeholder "funky_1a2b3c4d"
        // name: give it a random one (replacing whatever name this phone had
        // from before the account existed).
        unawaited(_assignRandomHandle());
      } else if (serverHandle != next.handle) {
        // The server's copy is what everyone else sees, so it wins — unless
        // you literally just renamed yourself and the update is still in flight.
        final last = next.lastHandleChangeAt;
        final justChanged = last != null && DateTime.now().millisecondsSinceEpoch - last < 60000;
        if (!justChanged) next = next.copyWith(handle: serverHandle);
      }
    }
    final serverBio = row['bio'] as String?;
    if (next.bio.isEmpty && serverBio != null && serverBio.isNotEmpty) next = next.copyWith(bio: serverBio);
    final avatarUrl = row['avatar_url'] as String?;
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      next = next.copyWith(photoUrl: avatarUrl);
    } else if (next.photoPath != null && !_avatarBackfillTried) {
      // A picture picked before it could be shared (older build, or the
      // server wasn't set up yet): upload it now so other people see it.
      _avatarBackfillTried = true;
      unawaited(_uploadAvatar(next.photoPath!));
    }
    final style = row['style'];
    final hasLocalStyle = next.nameBold || next.nameItalic || next.nameUnderline || next.nameCheckbox || next.nameColor != null;
    if (!hasLocalStyle && style is Map && style.isNotEmpty) {
      next = next.copyWith(
        nameBold: style['bold'] == true,
        nameItalic: style['italic'] == true,
        nameUnderline: style['underline'] == true,
        nameCheckbox: style['check'] == true,
        nameColor: (style['color'] as num?)?.toInt(),
      );
    }
    final serverStreakDay = row['move_streak_day'] as String?;
    final serverStreak = (row['move_streak'] as num?)?.toInt() ?? 0;
    if (serverStreakDay != null && (next.moveStreakDay == null || serverStreakDay.compareTo(next.moveStreakDay!) > 0)) {
      next = next.copyWith(moveStreak: serverStreak, moveStreakDay: serverStreakDay);
    }
    me = next;
    _profileSynced = true;
    notifyListeners();
    _persist();
    _maybePushProfile();
  }

  int _nonNegative(int n) => n < 0 ? 0 : n;

  Map<String, dynamic> _profilePayload() {
    final earned = me.points - _appliedBonus;
    return {
      'points': earned < 0 ? 0 : earned,
      'move': me.move,
      'move_session': me.move == null ? null : sessionKey(),
      'move_streak': me.moveStreak,
      'move_streak_day': me.moveStreakDay,
      'style': {
        'bold': me.nameBold,
        'italic': me.nameItalic,
        'underline': me.nameUnderline,
        'check': me.nameCheckbox,
        'color': me.nameColor,
      },
    };
  }

  /// Pushes your points/going-to/streak/name style up to your profile row —
  /// only after the first fetch of that row (so a fresh install can never
  /// overwrite the server with zeros), and only when something actually
  /// changed since the last push.
  void _maybePushProfile() {
    final uid = supabaseUserId;
    if (!_profileSynced || !signedIn || uid == null) return;
    final payload = _profilePayload();
    final encoded = jsonEncode(payload);
    if (encoded == _lastProfilePush) return;
    _lastProfilePush = encoded;
    _fireAndForgetUpdate('profiles', payload, uid);
  }

  // --- Friends -----------------------------------------------------------

  Future<void> _fetchRemoteFriendships() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await Supabase.instance.client.from('friendships').select();
      final friends = <String>[];
      final sent = <String>[];
      final received = <String>[];
      for (final r in rows) {
        final requester = r['requester_id'] as String?;
        final addressee = r['addressee_id'] as String?;
        final status = r['status'] as String?;
        if (requester == null || addressee == null) continue;
        final other = requester == uid ? addressee : requester;
        if (status == 'accepted') {
          friends.add(other);
        } else if (requester == uid) {
          sent.add(other);
        } else {
          received.add(other);
        }
      }
      await _ensurePeopleFor([...friends, ...sent, ...received]);
      me = me.copyWith(friends: friends, friendRequestsSent: sent, friendRequestsReceived: received);
      notifyListeners();
      _persist();
    } catch (_) {
      // Offline — the realtime channel re-reads on the next change.
    }
  }

  void _fireAndForgetFriendshipRemove(String personId) {
    final uid = supabaseUserId;
    if (!signedIn || uid == null || !_isRealPersonId(personId)) return;
    _fireAndForgetRemote(
      () => Supabase.instance.client
          .from('friendships')
          .delete()
          .or('and(requester_id.eq.$uid,addressee_id.eq.$personId),and(requester_id.eq.$personId,addressee_id.eq.$uid)'),
    );
  }

  // --- Places ------------------------------------------------------------

  Future<void> _fetchRemotePlaces({bool purge = false}) async {
    if (supabaseUserId == null) return;
    try {
      final client = Supabase.instance.client;
      if (purge) {
        // Best-effort cleanup of stale unverified places — anyone's app
        // may call this; it only ever deletes places already past their
        // night (see purge_stale_places in the SQL).
        try {
          await client.rpc('purge_stale_places');
        } catch (_) {}
      }
      final rows = await client.from('places').select();
      final confRows = await client.from('place_confirmations').select();
      _applyRemotePlaces(rows, confRows);
    } catch (_) {
      // Offline — keep whatever's showing.
    }
  }

  // --- Place picture suggestions ------------------------------------------

  /// Every picture waiting for approval — only ever filled for the admin.
  List<PlacePhotoSuggestion> pendingPhotoSuggestions = [];

  /// Places where YOU have a picture waiting for approval.
  Set<String> myPendingPhotoPlaces = {};

  Future<void> _fetchPhotoSuggestions() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('place_photo_suggestions')
          .select()
          .eq('status', 'pending')
          .order('created_at');
      final all = <PlacePhotoSuggestion>[];
      final mine = <String>{};
      for (final raw in rows) {
        final r = raw as Map<String, dynamic>;
        final id = r['id'] as String?;
        final placeId = r['place_id'] as String?;
        final url = r['url'] as String?;
        final by = r['user_id'] as String?;
        if (id == null || placeId == null || url == null || by == null) continue;
        if (by == uid) mine.add(placeId);
        all.add(PlacePhotoSuggestion(id: id, placeId: placeId, userId: by == uid ? 'me' : by, url: url));
      }
      myPendingPhotoPlaces = mine;
      pendingPhotoSuggestions = isAdmin ? all : [];
      notifyListeners();
    } catch (_) {
      // Offline, or phase 10 not run yet.
    }
  }

  /// Uploads [path] as a suggested picture for a place. Returns a message to
  /// show: for an admin it goes live right away, for everyone else it waits
  /// for approval. The result is [photoSuggestedMessage], [photoLiveMessage],
  /// or a plain-sentence error.
  static const photoSuggestedMessage = 'Thanks! Your picture is waiting for admin approval.';
  static const photoLiveMessage = 'Picture added.';

  Future<String> suggestPlacePhoto(String placeId, String path) async {
    final uid = supabaseUserId;
    if (uid == null) return 'Sign in to add a picture.';
    final url = await _uploadPlaceCover(uid, path);
    if (url == null) return "Couldn't upload that picture — try a smaller one.";
    try {
      final res = await Supabase.instance.client.rpc('suggest_place_photo', params: {'p_place': placeId, 'p_url': url}) as String?;
      await _fetchPhotoSuggestions();
      if (res == 'approved') {
        unawaited(_fetchRemotePlaces());
        return photoLiveMessage;
      }
      if (res == 'pending') return photoSuggestedMessage;
      if (res != null && res.startsWith('!')) return res.substring(1);
      return "Couldn't add that picture.";
    } catch (_) {
      return "Couldn't add that picture — check your connection and try again. (If this keeps happening, the latest database update may not have been run yet.)";
    }
  }

  Future<void> reviewPlacePhoto(String suggestionId, bool approve) async {
    if (!isAdmin) return;
    try {
      await Supabase.instance.client.rpc('review_place_photo', params: {'p_id': suggestionId, 'p_approve': approve});
    } catch (_) {}
    await _fetchPhotoSuggestions();
    if (approve) await _fetchRemotePlaces();
  }

  Future<void> clearPlacePhoto(String placeId) async {
    if (!isAdmin) return;
    try {
      await Supabase.instance.client.rpc('clear_place_photo', params: {'p_place': placeId});
    } catch (_) {}
    await _fetchRemotePlaces();
  }

  // --- Group chats ---------------------------------------------------------

  /// The groups you're in. Their messages live in [messages] under
  /// GroupChat.room ('grp_<id>'), same as DMs live under a dm_ room.
  List<GroupChat> groups = [];

  GroupChat? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Newest activity first — what the Messages tab lists.
  List<GroupChat> get groupConversations {
    int lastAt(GroupChat g) {
      var t = g.createdAt.millisecondsSinceEpoch;
      for (final m in messages) {
        if (m.room == g.room && m.t > t) t = m.t;
      }
      return t;
    }

    final list = [...groups];
    final at = {for (final g in list) g.id: lastAt(g)};
    list.sort((a, b) => at[b.id]!.compareTo(at[a.id]!));
    return list;
  }

  /// Friends who can be put in a group — real accounts only.
  List<Person> get groupablePeople {
    final out = <Person>[];
    for (final id in me.friends) {
      if (!_remotePersonIds.contains(id) || isBanned(id)) continue;
      final p = personById(id);
      if (p != null) out.add(p);
    }
    out.sort((a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()));
    return out;
  }

  Timer? _groupsRefreshTimer;
  void _scheduleGroupsRefresh() {
    _groupsRefreshTimer?.cancel();
    _groupsRefreshTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_fetchGroups()));
  }

  String _rpcMessage(Object e) {
    if (e is PostgrestException && e.message.isNotEmpty) return e.message;
    return "Couldn't do that — check your connection and try again.";
  }

  Future<void> _fetchGroups() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final client = Supabase.instance.client;
      final chatRows = await client.from('group_chats').select();
      final memberRows = await client.from('group_members').select();
      final membersByGroup = <String, List<String>>{};
      final others = <String>{};
      for (final raw in memberRows) {
        final r = raw as Map<String, dynamic>;
        final gid = r['group_id'] as String?;
        final u = r['user_id'] as String?;
        if (gid == null || u == null) continue;
        (membersByGroup[gid] ??= []).add(u == uid ? 'me' : u);
        if (u != uid) others.add(u);
      }
      final next = <GroupChat>[];
      for (final raw in chatRows) {
        final r = raw as Map<String, dynamic>;
        final id = r['id'] as String?;
        if (id == null) continue;
        final by = r['created_by'] as String?;
        next.add(GroupChat(
          id: id,
          name: (r['name'] as String?) ?? 'Group',
          memberIds: membersByGroup[id] ?? const ['me'],
          createdBy: by == uid ? 'me' : (by ?? ''),
          createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ));
      }
      if (others.isNotEmpty) await _ensurePeopleFor(others);
      groups = next;
      notifyListeners();
      await _fetchGroupMessages();
    } catch (_) {
      // Offline, or phase 11 not run yet.
    }
  }

  ChatMessage? _groupMessageFromRow(Map<String, dynamic> row) {
    final uid = supabaseUserId;
    if (uid == null) return null;
    final id = row['id'] as String?;
    final gid = row['group_id'] as String?;
    final sender = row['sender_id'] as String?;
    if (id == null || gid == null || sender == null) return null;
    final createdAt = DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    return ChatMessage(
      id: id,
      t: createdAt.millisecondsSinceEpoch,
      room: 'grp_$gid',
      uid: sender == uid ? 'me' : sender,
      text: row['text'] as String? ?? '',
      anon: false,
      mediaType: row['media_path'] != null ? (row['media_type'] as String? ?? 'image') : null,
    );
  }

  Future<String?> _signedGroupMediaUrl(Map<String, dynamic> row) async {
    final path = row['media_path'] as String?;
    if (path == null) return null;
    try {
      return await Supabase.instance.client.storage.from('group_media').createSignedUrl(path, 6 * 3600);
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchGroupMessages() async {
    if (supabaseUserId == null || groups.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('group_messages')
          .select()
          .order('created_at', ascending: false)
          .limit(500);
      final fetched = <ChatMessage>[];
      final senders = <String>{};
      var signed = 0;
      // Newest first, so the 40 media signings go to the newest ones.
      for (final raw in rows) {
        final row = raw as Map<String, dynamic>;
        var msg = _groupMessageFromRow(row);
        if (msg == null) continue;
        final mid = msg.id;
        final already = messages.any((m) => m.id == mid && m.mediaUrl != null);
        if (row['media_path'] != null && signed < 40 && !already) {
          final url = await _signedGroupMediaUrl(row);
          signed++;
          if (url != null) msg = msg.copyWith(mediaUrl: url);
        }
        fetched.add(msg);
        _remoteMessageIds.add(msg.id);
        if (msg.uid != 'me') senders.add(msg.uid);
      }
      if (senders.isNotEmpty) await _ensurePeopleFor(senders);
      final byId = {for (final m in fetched) m.id: m};
      var changed = false;
      messages = messages.map((m) {
        final f = byId[m.id];
        if (f == null || f.mediaUrl == null || m.mediaUrl != null) return m;
        changed = true;
        return m.copyWith(mediaUrl: f.mediaUrl);
      }).toList();
      final existing = messages.map((m) => m.id).toSet();
      final fresh = fetched.where((m) => !existing.contains(m.id)).toList().reversed.toList();
      if (fresh.isNotEmpty || changed) {
        messages = _capMessages([...messages, ...fresh]);
        notifyListeners();
        _persist();
      }
    } catch (_) {}
  }

  void _onRemoteGroupMessageInsert(Map<String, dynamic> row) {
    final base = _groupMessageFromRow(row);
    if (base == null) return;
    _remoteMessageIds.add(base.id);
    if (messages.any((m) => m.id == base.id)) return;
    unawaited(() async {
      var msg = base;
      final url = await _signedGroupMediaUrl(row);
      if (url != null) msg = msg.copyWith(mediaUrl: url);
      if (msg.uid != 'me') await _ensurePeopleFor([msg.uid]);
      if (messages.any((m) => m.id == msg.id)) return;
      messages = _capMessages([...messages, msg]);
      notifyListeners();
      _persist();
      // A message for a group we haven't heard of yet (we were just added).
      if (groupById(msg.room.substring(4)) == null) _scheduleGroupsRefresh();
    }());
  }

  /// Sends a text and/or photo/video to a group. Returns null on success,
  /// otherwise a message to show — same contract as sendDirectMessage.
  Future<String?> sendGroupMessage(String groupId, String text, {String? mediaPath, String? mediaType, bool skipCooldown = false}) async {
    if (selfBanned) return _bannedMessage;
    if (supabaseUserId == null) return 'Sign in to message a group.';
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (!skipCooldown && last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    final capped = text.length > _maxMessageLength ? text.substring(0, _maxMessageLength) : text;
    final mp = mediaPath;
    final mt = mediaType;
    final hasMedia = mp != null && mt != null;
    if (capped.trim().isEmpty && !hasMedia) return null;
    if (hasMedia) {
      if (!skipCooldown && _tooSoon('dmMedia', 5000)) return 'Slow down — one snap every few seconds.';
      try {
        final bytes = await File(mp!).length();
        if (mt == 'video' && bytes > maxDmVideoBytes) {
          return 'That video is too big — keep it under ${maxDmVideoBytes ~/ (1024 * 1024)} MB.';
        }
        if (mt != 'video' && bytes > maxDmImageBytes) {
          return 'That photo is too big — keep it under ${maxDmImageBytes ~/ (1024 * 1024)} MB.';
        }
      } catch (_) {
        return "Couldn't read that file.";
      }
    }
    final local = ChatMessage(
      id: 'grp_${DateTime.now().microsecondsSinceEpoch}',
      t: now,
      room: 'grp_$groupId',
      uid: 'me',
      text: capped,
      anon: false,
      status: 'sending',
      mediaType: hasMedia ? mt : null,
      mediaPath: hasMedia ? mp : null,
    );
    messages = _capMessages([...messages, local]);
    _lastMessageAt = now;
    notifyListeners();
    _persist();
    unawaited(_deliverGroupMessage(local, groupId));
    return null;
  }

  Future<void> _deliverGroupMessage(ChatMessage local, String groupId) async {
    final uid = supabaseUserId;
    if (uid == null) {
      _setMessageStatus(local.id, 'failed');
      return;
    }
    try {
      final client = Supabase.instance.client;
      String? storagePath;
      final localFile = local.mediaPath;
      if (localFile != null) {
        final bytes = await File(localFile).readAsBytes();
        final isVideo = local.mediaType == 'video';
        final dot = localFile.lastIndexOf('.');
        var ext = dot == -1 ? (isVideo ? 'mp4' : 'jpg') : localFile.substring(dot + 1).toLowerCase();
        if (ext.length > 5) ext = isVideo ? 'mp4' : 'jpg';
        storagePath = '$groupId/${uid}_${local.t}_${local.id.hashCode.abs()}.$ext';
        await client.storage.from('group_media').uploadBinary(
              storagePath,
              bytes,
              fileOptions: FileOptions(
                upsert: true,
                contentType: isVideo ? (ext == 'mov' ? 'video/quicktime' : 'video/mp4') : (ext == 'png' ? 'image/png' : 'image/jpeg'),
              ),
            );
      }
      final rows = await client.from('group_messages').insert({
        'group_id': groupId,
        'sender_id': uid,
        'text': local.text,
        if (storagePath != null) 'media_path': storagePath,
        if (storagePath != null) 'media_type': local.mediaType,
      }).select();
      final serverId = rows.first['id'] as String;
      _remoteMessageIds.add(serverId);
      messages = messages
          .where((m) => m.id != serverId)
          .map((m) => m.id == local.id ? m.copyWith(id: serverId, status: 'delivered') : m)
          .toList();
    } catch (e) {
      _sendErrors[local.id] = _friendlySendError(e);
      messages = messages.map((m) => m.id == local.id ? m.copyWith(status: 'failed') : m).toList();
    }
    notifyListeners();
    _persist();
  }

  /// Why the last createGroup call failed (null when it worked).
  String? lastGroupError;

  /// Makes a named group out of [memberIds] (your friends) and returns its
  /// id, or null with [lastGroupError] set.
  Future<String?> createGroup(String name, List<String> memberIds) async {
    lastGroupError = null;
    if (selfBanned) {
      lastGroupError = _bannedMessage;
      return null;
    }
    if (supabaseUserId == null) {
      lastGroupError = 'Sign in to start a group.';
      return null;
    }
    try {
      final res = await Supabase.instance.client.rpc('create_group', params: {'p_name': name.trim(), 'p_members': memberIds});
      final id = res as String?;
      await _fetchGroups();
      if (id == null) {
        lastGroupError = "Couldn't start that group.";
        return null;
      }
      if (groupById(id) == null) {
        // The refresh didn't land — show it from what we know.
        groups = [
          ...groups,
          GroupChat(id: id, name: name.trim(), memberIds: ['me', ...memberIds], createdBy: 'me', createdAt: DateTime.now()),
        ];
        notifyListeners();
      }
      return id;
    } catch (e) {
      lastGroupError = _rpcMessage(e);
      return null;
    }
  }

  /// Returns null on success, otherwise a message to show.
  Future<String?> renameGroup(String groupId, String name) async {
    try {
      await Supabase.instance.client.rpc('rename_group', params: {'p_group': groupId, 'p_name': name.trim()});
      await _fetchGroups();
      return null;
    } catch (e) {
      return _rpcMessage(e);
    }
  }

  Future<String?> addGroupMembers(String groupId, List<String> memberIds) async {
    try {
      await Supabase.instance.client.rpc('add_group_members', params: {'p_group': groupId, 'p_members': memberIds});
      await _fetchGroups();
      return null;
    } catch (e) {
      return _rpcMessage(e);
    }
  }

  Future<String?> leaveGroup(String groupId) async {
    try {
      await Supabase.instance.client.rpc('leave_group', params: {'p_group': groupId});
      groups = groups.where((g) => g.id != groupId).toList();
      messages = messages.where((m) => m.room != 'grp_$groupId').toList();
      notifyListeners();
      _persist();
      return null;
    } catch (e) {
      return _rpcMessage(e);
    }
  }

  // --- Profile reports ----------------------------------------------------

  /// Reports of profiles still waiting on the admin — only ever filled for
  /// the admin (the server won't hand them to anyone else).
  List<ProfileReport> openProfileReports = [];

  static const profileReportReasons = [
    'Spam or fake account',
    'Harassment or bullying',
    'Inappropriate photos',
    'Pretending to be someone',
    'Under 18',
    'Something else',
  ];

  Future<void> _fetchProfileReports() async {
    final uid = supabaseUserId;
    if (uid == null || !isAdmin) {
      if (openProfileReports.isNotEmpty) {
        openProfileReports = [];
        notifyListeners();
      }
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('profile_reports')
          .select()
          .eq('status', 'open')
          .order('created_at');
      final out = <ProfileReport>[];
      final ids = <String>{};
      for (final raw in rows) {
        final r = raw as Map<String, dynamic>;
        final id = r['id'] as String?;
        final reporter = r['reporter_id'] as String?;
        final reported = r['reported_id'] as String?;
        if (id == null || reporter == null || reported == null) continue;
        ids..add(reporter)..add(reported);
        out.add(ProfileReport(
          id: id,
          reporterId: reporter == uid ? 'me' : reporter,
          reportedId: reported == uid ? 'me' : reported,
          reason: (r['reason'] as String?) ?? '',
          createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ));
      }
      ids.remove(uid);
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      openProfileReports = out;
      notifyListeners();
    } catch (_) {
      // Offline, or phase 10 not run yet.
    }
  }

  /// Reports a profile. Returns a message to show the person.
  Future<String> reportProfile(String personId, String reason) async {
    if (supabaseUserId == null) return 'Sign in to report someone.';
    try {
      final res = await Supabase.instance.client.rpc('report_profile', params: {'p_user': personId, 'p_reason': reason}) as String?;
      return res ?? "Thanks — we'll take a look.";
    } catch (_) {
      return "Couldn't send that report — check your connection and try again.";
    }
  }

  Future<void> resolveProfileReport(String id) async {
    if (!isAdmin) return;
    try {
      await Supabase.instance.client.rpc('resolve_profile_report', params: {'p_id': id});
    } catch (_) {}
    await _fetchProfileReports();
  }

  // --- Place star ratings -------------------------------------------------

  /// Everyone's ratings per place (average + count) plus this person's own
  /// rating and next-allowed date — see supabase/phase9.sql.
  Map<String, PlaceRatingStats> placeRatings = {};

  PlaceRatingStats? ratingFor(String placeId) => placeRatings[placeId];

  Timer? _ratingsRefreshTimer;
  void _scheduleRatingsRefresh() {
    _ratingsRefreshTimer?.cancel();
    _ratingsRefreshTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_fetchPlaceRatings()));
  }

  Future<void> _fetchPlaceRatings() async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.rpc('place_rating_stats') as List<dynamic>;
      final next = <String, PlaceRatingStats>{};
      for (final raw in rows) {
        final r = raw as Map<String, dynamic>;
        final id = r['place_id'] as String?;
        if (id == null) continue;
        final nextRaw = r['my_next_at'] as String?;
        next[id] = PlaceRatingStats(
          avg: (r['avg_stars'] as num?)?.toDouble() ?? 0,
          count: (r['rating_count'] as num?)?.toInt() ?? 0,
          mine: (r['my_stars'] as num?)?.toDouble(),
          nextAt: nextRaw != null ? DateTime.tryParse(nextRaw)?.toLocal() : null,
        );
      }
      placeRatings = next;
      notifyListeners();
    } catch (_) {
      // Offline, or phase 9 not run yet — keep whatever's showing.
    }
  }

  /// Rates a place 0.5–5 stars. Returns null on success, otherwise a message
  /// to show (e.g. the once-a-month limit).
  Future<String?> ratePlace(String placeId, double stars) async {
    if (supabaseUserId == null) return 'Sign in to rate places.';
    try {
      final res = await Supabase.instance.client.rpc('rate_place', params: {'p_place': placeId, 'p_stars': stars});
      await _fetchPlaceRatings();
      return res as String?;
    } catch (_) {
      return "Couldn't save your rating — check your connection and try again.";
    }
  }

  /// Takes this person's rating back (they still wait out the month before
  /// rating the same place again).
  Future<void> removeMyRating(String placeId) async {
    if (supabaseUserId == null) return;
    try {
      await Supabase.instance.client.rpc('remove_my_rating', params: {'p_place': placeId});
    } catch (_) {}
    await _fetchPlaceRatings();
  }

  Place? _placeFromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final lat = (row['lat'] as num?)?.toDouble();
    final lng = (row['lng'] as num?)?.toDouble();
    if (id == null || lat == null || lng == null) return null;
    final createdRaw = row['created_at'] as String?;
    final created = createdRaw != null ? DateTime.parse(createdRaw).toLocal() : DateTime.now();
    final byUid = row['by_uid'] as String?;
    final kindName = row['kind'] as String?;
    return Place(
      id: id,
      name: (row['name'] as String?) ?? 'Unnamed place',
      kind: PlaceKind.values.firstWhere((k) => k.name == kindName, orElse: () => PlaceKind.area),
      lat: lat,
      lng: lng,
      address: (row['address'] as String?) ?? '',
      by: byUid == supabaseUserId ? 'me' : (byUid ?? 'deleted'),
      t: created.millisecondsSinceEpoch,
      session: sessionKey(created),
      coverPhotoPath: _localPlaceCovers[id],
      coverUrl: row['cover_url'] as String?,
      photoUrl: row['photo_url'] as String?,
    );
  }

  /// Replaces the backend-sourced places with a fresh copy. Tonight's places
  /// always show; an older one only survives if a FUNKY Admin verified it or
  /// 15+ people confirmed it — that's the nightly "unverified places clear
  /// out, verified ones stay" rule.
  void _applyRemotePlaces(List<dynamic> rows, List<dynamic> confRows) {
    final uid = supabaseUserId;
    final confByPlace = <String, List<String>>{};
    for (final c in confRows) {
      final pid = c['place_id'] as String?;
      final u = c['user_id'] as String?;
      if (pid == null || u == null) continue;
      (confByPlace[pid] ??= []).add(u == uid ? 'me' : u);
    }
    final today = sessionKey();
    final fetched = <Place>[];
    final verifiedByAdmin = <String>{};
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final place = _placeFromRow(row);
      if (place == null) continue;
      final adminVerified = row['admin_verified'] as bool? ?? false;
      final confirmations = confByPlace[place.id]?.length ?? 0;
      final verified = adminVerified || confirmations >= venueVerificationThreshold;
      if (place.session != today && !verified) continue;
      fetched.add(place);
      if (adminVerified) verifiedByAdmin.add(place.id);
    }
    final fetchedIds = fetched.map((p) => p.id).toSet();
    places = [...places.where((p) => !_remotePlaceIds.contains(p.id) && !fetchedIds.contains(p.id)), ...fetched];
    _remotePlaceIds
      ..clear()
      ..addAll(fetchedIds);
    adminVerifiedPlaceIds = verifiedByAdmin;
    placeConfirmations = {for (final id in fetchedIds) id: confByPlace[id] ?? const <String>[]};
    notifyListeners();
    _persist();
  }

  // --- Polls -------------------------------------------------------------

  Timer? _pollsRefreshTimer;
  void _schedulePollsRefresh() {
    _pollsRefreshTimer?.cancel();
    _pollsRefreshTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_fetchRemotePolls()));
  }

  Poll? _pollFromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final q = row['q'] as String?;
    final lat = (row['lat'] as num?)?.toDouble();
    final lng = (row['lng'] as num?)?.toDouble();
    final optionsRaw = row['options'];
    if (id == null || q == null || lat == null || lng == null || optionsRaw is! List) return null;
    final createdRaw = row['created_at'] as String?;
    final created = createdRaw != null ? DateTime.parse(createdRaw).toLocal() : DateTime.now();
    final byUid = row['by_uid'] as String?;
    return Poll(
      id: id,
      q: q,
      options: optionsRaw.map((e) => e.toString()).toList(),
      lat: lat,
      lng: lng,
      by: byUid == supabaseUserId ? 'me' : (byUid ?? 'deleted'),
      t: created.millisecondsSinceEpoch,
      session: sessionKey(created),
    );
  }

  Future<void> _fetchRemotePolls() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('polls').select();
      final voteRows = await client.from('poll_votes').select();
      final today = sessionKey();
      final fetched = <Poll>[];
      for (final row in rows) {
        final poll = _pollFromRow(row);
        // Polls are tonight-only — an older one is just left behind.
        if (poll == null || poll.session != today) continue;
        fetched.add(poll);
      }
      final fetchedIds = fetched.map((p) => p.id).toSet();
      final votes = <String, Map<String, int>>{};
      var myVotes = Map<String, int>.from(me.votes);
      for (final v in voteRows) {
        final pid = v['poll_id'] as String?;
        final voter = v['user_id'] as String?;
        final idx = (v['option_idx'] as num?)?.toInt();
        if (pid == null || voter == null || idx == null || !fetchedIds.contains(pid)) continue;
        if (voter == uid) {
          // Your own vote on a poll (maybe cast on another device).
          myVotes[pid] = idx;
        } else {
          (votes[pid] ??= {})[voter] = idx;
        }
      }
      polls = [...polls.where((p) => !_remotePollIds.contains(p.id) && !fetchedIds.contains(p.id)), ...fetched];
      _remotePollIds
        ..clear()
        ..addAll(fetchedIds);
      _remotePollVotes
        ..clear()
        ..addAll(votes);
      // Drop votes recorded on polls that no longer exist.
      myVotes.removeWhere((pid, _) => !fetchedIds.contains(pid));
      me = me.copyWith(votes: myVotes);
      notifyListeners();
      _persist();
    } catch (_) {
      // Offline — keep what's showing.
    }
  }

  // --- Place reports -----------------------------------------------------

  Timer? _reportsRefreshTimer;
  void _scheduleReportsRefresh() {
    _reportsRefreshTimer?.cancel();
    _reportsRefreshTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_fetchRemoteReports()));
  }

  Future<void> _fetchRemoteReports() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final client = Supabase.instance.client;
      final cutoff = DateTime.fromMillisecondsSinceEpoch(_sessionStartMs()).toUtc().toIso8601String();
      final rows = await client.from('place_reports').select().gte('created_at', cutoff);
      final confRows = await client.from('report_confirmations').select();
      final confByReport = <String, List<String>>{};
      for (final c in confRows) {
        final rid = c['report_id'] as String?;
        final voter = c['user_id'] as String?;
        if (rid == null || voter == null) continue;
        (confByReport[rid] ??= []).add(voter == uid ? 'me' : voter);
      }
      final fetched = <PlaceReport>[];
      for (final row in rows) {
        final id = row['id'] as String?;
        final placeId = row['place_id'] as String?;
        final kindName = row['kind'] as String?;
        if (id == null || placeId == null || kindName == null) continue;
        final kind = ReportKind.values.where((k) => k.name == kindName);
        if (kind.isEmpty) continue;
        final createdRaw = row['created_at'] as String?;
        final created = createdRaw != null ? DateTime.parse(createdRaw).toLocal() : DateTime.now();
        final reporter = row['reporter_id'] as String? ?? 'deleted';
        final confirmed = {...(confByReport[id] ?? const <String>[]), if (reporter != 'deleted') (reporter == uid ? 'me' : reporter)}.toList();
        fetched.add(PlaceReport(
          id: id,
          placeId: placeId,
          kind: kind.first,
          detail: row['detail'] as String?,
          t: created.millisecondsSinceEpoch,
          reporterId: reporter == uid ? 'me' : reporter,
          confirmedBy: confirmed,
        ));
      }
      final fetchedIds = fetched.map((r) => r.id).toSet();
      placeReports = [...placeReports.where((r) => !_remoteReportIds.contains(r.id) && !fetchedIds.contains(r.id)), ...fetched];
      _remoteReportIds
        ..clear()
        ..addAll(fetchedIds);
      notifyListeners();
      _persist();
    } catch (_) {
      // Offline — keep what's showing.
    }
  }

  // --- Live Chat ---------------------------------------------------------

  int _sessionStartMs() {
    final day = DateTime.tryParse(sessionKey());
    if (day == null) return DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    return day.add(const Duration(hours: resetHour)).millisecondsSinceEpoch;
  }

  ChatMessage? _chatFromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final text = row['text'] as String?;
    if (id == null || text == null) return null;
    final createdRaw = row['created_at'] as String?;
    final created = createdRaw != null ? DateTime.parse(createdRaw).toLocal() : DateTime.now();
    final anon = row['anon'] as bool? ?? false;
    final sender = row['sender_id'] as String?;
    final String uid;
    if (sender == null) {
      uid = 'anon';
    } else {
      uid = sender == supabaseUserId ? 'me' : sender;
    }
    return ChatMessage(
      id: id,
      t: created.millisecondsSinceEpoch,
      room: 'main',
      uid: uid,
      text: text,
      anon: anon,
      status: 'delivered',
      lat: (row['lat'] as num?)?.toDouble(),
      lng: (row['lng'] as num?)?.toDouble(),
    );
  }

  Future<void> _fetchRemoteChat() async {
    if (supabaseUserId == null) return;
    try {
      final cutoff = DateTime.fromMillisecondsSinceEpoch(_sessionStartMs()).toUtc().toIso8601String();
      final rows = await Supabase.instance.client
          .from('chat_messages')
          .select()
          .gte('created_at', cutoff)
          .order('created_at', ascending: false)
          .limit(300);
      final fetched = <ChatMessage>[];
      for (final row in rows) {
        final msg = _chatFromRow(row);
        if (msg == null) continue;
        fetched.add(msg);
        _remoteChatIds.add(msg.id);
      }
      await _ensurePeopleFor(fetched.map((m) => m.uid).where((u) => u != 'anon' && u != 'me'));
      final existingIds = messages.map((m) => m.id).toSet();
      final newOnes = fetched.where((m) => !existingIds.contains(m.id)).toList();
      if (newOnes.isNotEmpty) {
        messages = _capMessages([...messages, ...newOnes]);
        notifyListeners();
      }
      await _fetchRemoteReactions();
    } catch (_) {
      // Offline — realtime / next sync catches up.
    }
  }

  void _onRemoteChatInsert(Map<String, dynamic> row) {
    final msg = _chatFromRow(row);
    if (msg == null) return;
    _remoteChatIds.add(msg.id);
    if (messages.any((m) => m.id == msg.id)) return;
    unawaited(() async {
      if (msg.uid != 'anon' && msg.uid != 'me') await _ensurePeopleFor([msg.uid]);
      if (messages.any((m) => m.id == msg.id)) return;
      messages = _capMessages([...messages, msg]);
      notifyListeners();
    }());
  }

  void _onRemoteChatDelete(Map<String, dynamic> oldRow) {
    final id = oldRow['id'] as String?;
    if (id == null) return;
    _remoteChatIds.remove(id);
    final before = messages.length;
    messages = messages.where((m) => m.id != id).toList();
    if (messages.length != before) notifyListeners();
  }

  /// The Live Chat feed for display: tonight's area messages from people
  /// within 25 miles of where you are (a message with no recorded location
  /// is always shown), minus anyone who's banned.
  List<ChatMessage> get liveChatMessages {
    final here = location ?? defaultLocation;
    final start = _sessionStartMs();
    final list = messages.where((m) {
      if (m.room != 'main') return false;
      if (m.t < start) return false;
      if (m.uid != 'me' && isBanned(m.uid)) return false;
      final lat = m.lat;
      final lng = m.lng;
      if (lat != null && lng != null && !near(here, LatLng(lat, lng))) return false;
      return true;
    }).toList();
    list.sort((a, b) => a.t.compareTo(b.t));
    return list;
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
        if (row['banned'] == true) _remoteBannedIds.add(id);
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
    final style = row['style'];
    final styleMap = style is Map ? style : const <dynamic, dynamic>{};
    // Only count their "going" pick if it was made tonight — an old one
    // from a previous night is just a stale value.
    final moveSession = row['move_session'] as String?;
    final move = moveSession == sessionKey() ? row['move'] as String? : null;
    return Person(
      id: id,
      handle: (row['handle'] as String?) ?? 'funky_${id.substring(0, 8)}',
      bio: (row['bio'] as String?) ?? '',
      since: 0,
      // Earned points plus any admin-gifted bonus — what everyone sees.
      points: _nonNegative(((row['points'] as num?)?.toInt() ?? 0) + ((row['bonus_points'] as num?)?.toInt() ?? 0)),
      friends: const [],
      friendRequestsSent: const [],
      friendRequestsReceived: const [],
      muted: const [],
      anon: false,
      session: sessionKey(),
      move: move,
      votes: const {},
      seen: const [],
      likes: const [],
      // Their profile picture is a public URL (avatars bucket), not a local
      // file — FunkyAvatar shows photoUrl when there's no photoPath.
      photoPath: null,
      photoUrl: row['avatar_url'] as String?,
      nameBold: styleMap['bold'] == true,
      nameItalic: styleMap['italic'] == true,
      nameUnderline: styleMap['underline'] == true,
      nameCheckbox: styleMap['check'] == true,
      nameColor: (styleMap['color'] as num?)?.toInt(),
      moveStreak: (row['move_streak'] as num?)?.toInt() ?? 0,
      moveStreakDay: row['move_streak_day'] as String?,
      isAdminUser: row['is_admin'] as bool? ?? false,
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
      // Never lose "I watched / liked this" just because the server list
      // doesn't have it (yet) — the local copy is the fresher truth.
      final views = existingLocal != null && existingLocal.views.contains('me') && !story.views.contains('me') ? [...story.views, 'me'] : story.views;
      final likes = existingLocal != null && existingLocal.likes.contains('me') && !story.likes.contains('me') ? [...story.likes, 'me'] : story.likes;
      if (existingLocal != null && (existingLocal.imagePath != null || existingLocal.videoPath != null)) {
        byId[story.id] = existingLocal.copyWith(views: views, likes: likes, savedToTimeline: story.savedToTimeline);
      } else {
        byId[story.id] = story.copyWith(views: views, likes: likes);
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
        (viewsByStory[sid] ??= []).add(_asMe(v['viewer_id'] as String));
      }
      final likesByStory = <String, List<String>>{};
      for (final l in likeRows) {
        final sid = l['story_id'] as String;
        (likesByStory[sid] ??= []).add(_asMe(l['liker_id'] as String));
      }
      final fetched = <Story>[];
      for (final row in rows) {
        final story = await _storyFromRow(row, views: viewsByStory[row['id']] ?? const [], likes: likesByStory[row['id']] ?? const []);
        if (story != null) fetched.add(story);
      }
      await _ensurePeopleFor(fetched.map((s) => s.uid));
      // Stories that were deleted or expired on the server disappear here
      // too (a story posted in the last two minutes is spared in case its
      // upload is still landing).
      final fetchedIds = fetched.map((s) => s.id).toSet();
      final recent = DateTime.now().millisecondsSinceEpoch - 120000;
      final before = stories.length;
      stories = stories.where((s) => !_remoteStoryIds.contains(s.id) || fetchedIds.contains(s.id) || s.t > recent).toList();
      _remoteStoryIds.removeWhere((id) => !fetchedIds.contains(id) && !stories.any((s) => s.id == id));
      if (stories.length != before) {
        notifyListeners();
        _persist();
      }
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
    final viewer = _asMe(viewerId);
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1 || stories[i].views.contains(viewer)) return;
    stories = [...stories]..[i] = stories[i].copyWith(views: [...stories[i].views, viewer]);
    notifyListeners();
    _persist();
  }

  void _onRemoteStoryLikeChange(Map<String, dynamic> row, bool added) {
    final storyId = row['story_id'] as String?;
    final likerId = row['liker_id'] as String?;
    if (storyId == null || likerId == null) return;
    final liker = _asMe(likerId);
    final i = stories.indexWhere((s) => s.id == storyId);
    if (i == -1) return;
    final current = stories[i].likes;
    final next = added ? (current.contains(liker) ? current : [...current, liker]) : current.where((id) => id != liker).toList();
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
      status: senderId == uid && row['read_at'] != null ? 'seen' : 'delivered',
      mediaType: row['media_path'] != null ? (row['media_type'] as String? ?? 'image') : null,
    );
  }

  /// A short-lived signed URL for a DM photo/video (the dm_media bucket is
  /// private). Null if the row has no media or signing fails.
  Future<String?> _signedDmMediaUrl(Map<String, dynamic> row) async {
    final path = row['media_path'] as String?;
    if (path == null) return null;
    try {
      return await Supabase.instance.client.storage.from('dm_media').createSignedUrl(path, 6 * 3600);
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchRemoteMessages() async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.from('messages').select().order('created_at');
      final fetched = <ChatMessage>[];
      final urls = <String, String>{};
      final otherIds = <String>{};
      for (final row in rows) {
        var msg = _messageFromRow(row);
        if (msg == null) continue;
        if (row['media_path'] != null) {
          final url = await _signedDmMediaUrl(row);
          if (url != null) {
            urls[msg.id] = url;
            msg = msg.copyWith(mediaUrl: url);
          }
        }
        fetched.add(msg);
        _remoteMessageIds.add(msg.id);
        final sender = row['sender_id'] as String;
        final recipient = row['recipient_id'] as String;
        otherIds.add(sender == supabaseUserId ? recipient : sender);
      }
      await _ensurePeopleFor(otherIds);
      final byId = {for (final m in fetched) m.id: m};
      // Existing ones: refresh the delivery status (so "Delivered" becomes
      // "Seen") and re-attach a fresh download URL to remote media.
      var changed = false;
      messages = messages.map((m) {
        final f = byId[m.id];
        if (f == null) return m;
        final nextStatus = m.uid == 'me' && f.status == 'seen' ? 'seen' : m.status;
        final needUrl = urls[m.id] != null && m.mediaUrl == null;
        if (nextStatus == m.status && !needUrl) return m;
        changed = true;
        return m.copyWith(status: nextStatus, mediaUrl: needUrl ? urls[m.id] : null);
      }).toList();
      final existingIds = messages.map((m) => m.id).toSet();
      final newOnes = fetched.where((m) => !existingIds.contains(m.id)).toList();
      if (newOnes.isNotEmpty || changed) {
        messages = _capMessages([...messages, ...newOnes]);
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
    final base = _messageFromRow(row);
    if (base == null) return;
    _remoteMessageIds.add(base.id);
    // Already here — either a duplicate delivery of the same realtime event
    // or something a fetch already brought in.
    if (messages.any((m) => m.id == base.id)) return;
    unawaited(() async {
      var msg = base;
      final url = await _signedDmMediaUrl(row);
      if (url != null) msg = msg.copyWith(mediaUrl: url);
      await _ensurePeopleFor([msg.uid]);
      // Re-check: the send path may have swapped in this id while we waited.
      if (messages.any((m) => m.id == msg.id)) return;
      messages = _capMessages([...messages, msg]);
      notifyListeners();
      _persist();
    }());
  }

  /// The other side opened the thread — flip my message to "Seen".
  void _onRemoteMessageUpdate(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null || row['read_at'] == null) return;
    final i = messages.indexWhere((m) => m.id == id);
    if (i == -1 || messages[i].uid != 'me' || messages[i].status == 'seen') return;
    _setMessageStatus(id, 'seen');
  }


  // ---------------------------------------------------------------------
  // @mentions in the live chat: the picker that opens when you type "@".
  // ---------------------------------------------------------------------

  /// People already known on this device whose @name matches [query] —
  /// friends first, then names that START with it, then names that merely
  /// contain it. Instant (no network); see [lookupMentionHandles] for the
  /// wider lookup.
  List<Person> mentionCandidates(String query) {
    final q = query.toLowerCase();
    final friendIds = me.friends.toSet();
    final found = people.values.where((p) {
      if (!_isRealPersonId(p.id) || p.handle.isEmpty || isBanned(p.id)) return false;
      return q.isEmpty || p.handle.toLowerCase().contains(q);
    }).toList();
    int rank(Person p) {
      final h = p.handle.toLowerCase();
      var r = h.startsWith(q) ? 0 : 2;
      if (friendIds.contains(p.id)) r -= 1;
      return r;
    }
    found.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.handle.toLowerCase().compareTo(b.handle.toLowerCase());
    });
    return found.take(6).toList();
  }

  /// Looks up accounts whose @name starts with [query] on the server (anyone
  /// signed up, not just people already on this device) and remembers them,
  /// so the picker can show them. Returns true if anyone new turned up.
  Future<bool> lookupMentionHandles(String query) async {
    final q = query.trim();
    if (!signedIn || supabaseUserId == null || q.isEmpty) return false;
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select()
          .ilike('handle', '${q.replaceAll('_', r'\_')}%')
          .limit(8);
      var added = false;
      final updated = Map<String, Person>.from(people);
      for (final row in rows) {
        final id = row['id'] as String?;
        if (id == null || id == supabaseUserId || updated.containsKey(id)) continue;
        updated[id] = _personFromProfileRow(row);
        _remotePersonIds.add(id);
        if (row['banned'] == true) _remoteBannedIds.add(id);
        added = true;
      }
      if (added) {
        people = updated;
        notifyListeners();
      }
      return added;
    } catch (_) {
      return false;
    }
  }

  /// A server user id as the app writes it locally: 'me' for yourself.
  String _asMe(String id) => id == supabaseUserId ? 'me' : id;

  // ---------------------------------------------------------------------
  // Keeping the feed fresh without closing the app: a refresh whenever the
  // app comes back to the foreground, plus a light one every 30 seconds
  // while it's open (realtime is still the instant path; this is the
  // safety net for when the connection dropped in the background).
  // ---------------------------------------------------------------------

  Timer? _autoRefreshTimer;
  DateTime? _lastFullRefresh;

  void setAppForeground(bool foreground) {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    if (!foreground) return;
    if (supabaseUserId != null) {
      final last = _lastFullRefresh;
      // Away for a while: the realtime sockets are probably dead, so
      // rebuild them along with a full re-fetch.
      if (last != null && DateTime.now().difference(last) > const Duration(seconds: 20)) {
        refreshNow(rebuildRealtime: true);
      }
    }
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => refreshNow());
  }

  Future<void> refreshNow({bool rebuildRealtime = false}) async {
    if (!signedIn || supabaseUserId == null) return;
    _lastFullRefresh = DateTime.now();
    if (rebuildRealtime) {
      _startRemoteSync();
      return;
    }
    await Future.wait([
      _fetchRemoteStories(),
      _fetchRemoteProfiles(othersOnly: true),
      _fetchRemoteFriendships(),
      _fetchRemotePlaces(),
      _fetchPlaceRatings(),
      _fetchPhotoSuggestions(),
      _fetchProfileReports(),
      _fetchGroups(),
      _fetchRemoteMessages(),
      _fetchNotifications(),
    ]);
  }

  // ---------------------------------------------------------------------
  // Notifications (DMs, friend requests, new verified places nearby,
  // reports at the place you're going to). The server creates them with
  // triggers (supabase/phase7.sql); this just reads them, keeps them live,
  // and registers this phone for iPhone pushes (supabase/functions/send-push).
  // ---------------------------------------------------------------------

  List<AppNotification> notifications = [];
  NotificationPrefs notifPrefs = const NotificationPrefs();
  RealtimeChannel? _notificationsChannel;
  String? _pushToken;
  LatLng? _syncedLocation;
  DateTime? _syncedLocationAt;

  int get unreadNotificationCount => notifications.where((n) => !n.read).length;

  void _syncBadge() => unawaited(PushService.setBadge(unreadNotificationCount));

  Future<void> _fetchNotifications() async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.from('notifications').select().order('created_at', ascending: false).limit(100);
      final list = <AppNotification>[];
      for (final row in rows) {
        final n = AppNotification.fromRow(row);
        if (n != null) list.add(n);
      }
      notifications = list;
      _syncBadge();
      notifyListeners();
    } catch (_) {
      // Not set up yet (phase 7 SQL not run) or offline — the bell just stays empty.
    }
  }

  void _onRemoteNotification(Map<String, dynamic> row) {
    final n = AppNotification.fromRow(row);
    if (n == null) return;
    final i = notifications.indexWhere((x) => x.id == n.id);
    if (i == -1) {
      notifications = [n, ...notifications];
    } else {
      final next = List<AppNotification>.from(notifications);
      next[i] = n;
      notifications = next;
    }
    _syncBadge();
    notifyListeners();
  }

  Future<void> markNotificationRead(String id) async {
    final i = notifications.indexWhere((n) => n.id == id);
    if (i == -1 || notifications[i].read) return;
    final next = List<AppNotification>.from(notifications);
    next[i] = next[i].copyWith(read: true);
    notifications = next;
    _syncBadge();
    notifyListeners();
    try {
      await Supabase.instance.client.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);
    } catch (_) {}
  }

  Future<void> markAllNotificationsRead() async {
    final uid = supabaseUserId;
    if (uid == null || unreadNotificationCount == 0) return;
    notifications = notifications.map((n) => n.read ? n : n.copyWith(read: true)).toList();
    _syncBadge();
    notifyListeners();
    try {
      await Supabase.instance.client
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('user_id', uid)
          .filter('read_at', 'is', null);
    } catch (_) {}
  }

  Future<void> clearAllNotifications() async {
    final uid = supabaseUserId;
    if (uid == null || notifications.isEmpty) return;
    notifications = [];
    _syncBadge();
    notifyListeners();
    try {
      await Supabase.instance.client.from('notifications').delete().eq('user_id', uid);
    } catch (_) {}
  }

  /// Makes sure [id]'s profile is loaded so a screen opened from a
  /// notification (a DM thread, a profile) has someone to show.
  Future<void> ensurePerson(String id) => _ensurePeopleFor([id]);

  Future<void> _fetchNotifPrefs() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client.from('notification_prefs').select().eq('user_id', uid).maybeSingle();
      if (row != null) {
        notifPrefs = NotificationPrefs.fromRow(row);
        notifyListeners();
      }
    } catch (_) {}
    _syncLocationUp();
  }

  Future<void> setNotifPref(String kind, bool on) async {
    final uid = supabaseUserId;
    final next = switch (kind) {
      'dm' => notifPrefs.copyWith(dm: on),
      'friend' => notifPrefs.copyWith(friend: on),
      'place' => notifPrefs.copyWith(place: on),
      'report' => notifPrefs.copyWith(report: on),
      'mention' => notifPrefs.copyWith(mention: on),
      _ => notifPrefs,
    };
    notifPrefs = next;
    notifyListeners();
    if (uid == null) return;
    try {
      await Supabase.instance.client.from('notification_prefs').upsert(next.toRow(uid));
    } catch (_) {}
    if (kind == 'place') {
      if (on) {
        _syncedLocationAt = null;
        _syncLocationUp();
      } else {
        // No new-place alerts means no reason to keep a location on file.
        _syncedLocation = null;
        _syncedLocationAt = null;
        try {
          await Supabase.instance.client.from('user_locations').delete().eq('user_id', uid);
        } catch (_) {}
      }
    }
  }

  Future<void> _registerPush() async {
    if (!Platform.isIOS) return;
    await PushService.start((token) {
      _pushToken = token;
      unawaited(_uploadPushToken(token));
    });
  }

  Future<void> _uploadPushToken(String token) async {
    if (supabaseUserId == null) return;
    try {
      await Supabase.instance.client.rpc('register_device_token', params: {'p_token': token, 'p_platform': 'ios'});
    } catch (_) {}
  }

  Future<void> _unregisterPush() async {
    final token = _pushToken;
    _pushToken = null;
    if (token == null || supabaseUserId == null) return;
    try {
      await Supabase.instance.client.from('device_tokens').delete().eq('token', token);
    } catch (_) {}
  }

  /// Tells the server roughly where you last opened the app — only used to
  /// work out whether a newly verified place is within 25 miles of you, and
  /// only visible to you. Throttled: at most every 30 min unless you moved
  /// more than a mile.
  void _syncLocationUp() {
    final uid = supabaseUserId;
    final loc = location;
    if (uid == null || loc == null || !notifPrefs.place) return;
    final prev = _syncedLocation;
    final at = _syncedLocationAt;
    if (prev != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 30) && milesBetween(prev, loc) < 1) return;
    _syncedLocation = loc;
    _syncedLocationAt = DateTime.now();
    unawaited(() async {
      try {
        await Supabase.instance.client.from('user_locations').upsert({
          'user_id': uid,
          'lat': loc.lat,
          'lng': loc.lng,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {
        _syncedLocationAt = null;
      }
    }());
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _persistTimer?.cancel();
    _authSub?.cancel();
    _stopRemoteSync();
    super.dispose();
  }
}
