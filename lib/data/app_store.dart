import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/address_search.dart';
import '../services/osm_venues.dart';
import '../services/push_service.dart';
import 'geo.dart';
import 'call_models.dart';
import 'group_models.dart';
import 'mock_data.dart';
import 'models.dart';
import 'notification_models.dart';
import 'place_photo.dart';
import 'place_rating.dart';
import 'post_models.dart';
import 'supabase_config.dart';
import 'venue_models.dart';
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

  // --- Blocking (phase 31) ------------------------------------------------
  // People you blocked, and people who blocked you. Either way the two of
  // you stop seeing each other's posts, stories, comments, chat and DMs.
  Set<String> _blockedByMe = {};
  Set<String> _blockedMe = {};

  bool isBlocked(String personId) => _blockedByMe.contains(personId);
  bool hasBlockedMe(String personId) => _blockedMe.contains(personId);

  /// Banned, blocked by you, or blocking you — keep them out of everything.
  bool isHidden(String personId) => isBanned(personId) || _blockedByMe.contains(personId) || _blockedMe.contains(personId);

  List<Person> get blockedPeople => _blockedByMe.map(personById).whereType<Person>().toList();

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
      // Through the server's bonus column, same as for anyone else — so a
      // removal sticks instead of the higher number coming back on the
      // next sync (earned points only ever sync upward).
      final uid = supabaseUserId;
      if (signedIn && uid != null) {
        try {
          await Supabase.instance.client.rpc('admin_give_points', params: {'target': uid, 'amount': amount});
        } catch (e) {
          return "Couldn't change your points — ${_friendlySendError(e)}";
        }
      }
      final next = me.points + amount < 0 ? 0 : me.points + amount;
      _appliedBonus += next - me.points;
      me = me.copyWith(points: next);
      _dropLockedNameStyles();
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
    await table('Story reply previews (phase 25)', 'messages', 'id,story_id,story_media_path');
    await table('Story reports (phase 26)', 'story_reports', 'id');
    await table('Places you\'ve been (phase 27)', 'place_visits', 'place_id,night');
    await table('Posts + comments (phase 29)', 'post_comments', 'id,post_id');
    await table('Blocking, events, delete account (phase 31)', 'event_going', 'post_id');
    await table('Crash reports + top-post points (phase 32)', 'post_awards', 'post_id');
    await table('Upcoming, chat replies, GIFs, online count (phase 33)', 'place_rsvps', 'place_id');
    await table('Dated parties + events at bars (phase 33)', 'places', 'starts_at,event_type,host_place_id');
    await table('Chat replies, spots, polls, GIFs (phase 33)', 'chat_messages', 'reply_to,place_id,poll_id,gif_url');
    await table('GIFs in DMs and groups (phase 34)', 'messages', 'gif_url');
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
    _chatReplayPool = _chatReplayPool.where((m) => m.id != messageId).toList();
    notifyListeners();
    _persist();
    if (_remoteChatIds.remove(messageId)) {
      _fireAndForgetRemote(() => Supabase.instance.client.from('chat_messages').delete().eq('id', messageId));
    }
  }

  /// Permanently deletes a poll (and scrubs its id out of everyone's votes,
  /// including your own, so a stray old vote can't ever point at something
  /// that no longer exists). Allowed for the admin and for whoever asked the
  /// poll; silently does nothing for anyone else. Also removes it on the
  /// server so it doesn't come back on the next refresh.
  /// Deletes your poll (or any, for an admin). Returns an error to show, or
  /// null. The server delete is waited on, so a poll that couldn't be
  /// deleted comes back with a reason instead of silently reappearing.
  Future<String?> deletePoll(String pollId) async {
    final target = polls.where((p) => p.id == pollId).toList();
    if (target.isEmpty) return null;
    if (!isAdmin && target.first.by != 'me') return "You can only delete your own polls.";
    final wasRemote = _remotePollIds.contains(pollId);
    if (wasRemote) {
      try {
        final rows = await Supabase.instance.client.from('polls').delete().eq('id', pollId).select('id');
        if (rows.isEmpty) return "Couldn't delete that poll — try again.";
      } catch (e) {
        final m = e.toString();
        if (m.contains('chat_messages_text_ok')) {
          return "Couldn't delete it yet — run the latest RUN_ALL.sql (phase 40) in Supabase.";
        }
        return "Couldn't delete that poll — check your connection and try again.";
      }
    }
    polls = polls.where((p) => p.id != pollId).toList();
    me = me.copyWith(votes: Map<String, int>.from(me.votes)..remove(pollId));
    people = {
      for (final entry in people.entries) entry.key: entry.value.copyWith(votes: Map<String, int>.from(entry.value.votes)..remove(pollId)),
    };
    _remotePollVotes.remove(pollId);
    _remotePollIds.remove(pollId);
    _pollComments.remove(pollId);
    notifyListeners();
    _persist();
    return null;
  }

  /// Admin-only — sets your own points to the max, comfortably past every
  /// level title and badge threshold (see levelTitles in models.dart), so
  /// the points/levels/badges UI can be tested without actually grinding
  /// for it. Silently does nothing for a non-admin account.
  void maxOutMyPoints() {
    if (!isAdmin) return;
    unawaited(adminGivePoints('me', 999999 - me.points));
  }

  /// After points go down: switch off any name style you no longer have
  /// the points for.
  void _dropLockedNameStyles() {
    final p = me.points;
    me = me.copyWith(
      nameBold: me.nameBold && canUseBoldName(p),
      nameItalic: me.nameItalic && canUseItalicName(p),
      nameUnderline: me.nameUnderline && canUseUnderlineName(p),
      nameCheckbox: me.nameCheckbox && canUseCheckName(p),
      clearNameEffect: me.nameEffect != null && !canUseNameEffect(me.nameEffect, p),
    );
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
    if (canUseServer && uid != null && _remotePlaceIds.contains(placeId)) {
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
    if (!signedIn) return; // guests don't earn points
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

  /// Turns on an animated name — 'cycle' (5,000 points) or 'rain'
  /// (10,000) — or, with null, turns it off. Only one at a time; one
  /// that isn't unlocked yet is ignored.
  void setNameEffect(String? effect) {
    if (effect != null && !canUseNameEffect(effect, me.points)) return;
    me = effect == null ? me.copyWith(clearNameEffect: true) : me.copyWith(nameEffect: effect);
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
    if (placesBeenCount >= 20) badges.add(const FunkyBadge('🗺️', 'Explorer'));
    return badges;
  }

  /// The blue-check "this person's reports are worth trusting more"
  /// signal — still doesn't skip the normal 8-confirmation report
  /// verification, it just colors how much weight people give an
  /// unverified report from this account.
  bool get isVerifiedUser => me.points >= 1000 && myStories.length >= 10;

  // Where your phone really is (GPS).
  LatLng? _gpsLocation;

  /// Admin "view another area": a spot an admin dropped their pin on to
  /// watch what's going on there. While it's set, everything (places, live
  /// chat, polls, stories, the map) acts as if you were standing there —
  /// until you tap "Return to my location". It's never sent to the server,
  /// and the 2-mile place-story check always uses your real location.
  LatLng? locationOverride;

  /// Where the app treats you as being: your dropped pin (admins), else GPS.
  LatLng? get location => (isAdmin ? locationOverride : null) ?? _gpsLocation;

  /// Your real GPS position, ignoring any dropped pin.
  LatLng? get gpsLocation => _gpsLocation;

  bool get isViewingElsewhere => isAdmin && locationOverride != null;

  static const _viewAsKey = 'funky.viewAs';

  /// Admin: pretend to be at [to] (null = back to your real location).
  Future<void> setLocationOverride(LatLng? to) async {
    if (to != null && !isAdmin) return;
    locationOverride = to;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (to == null) {
        await prefs.remove(_viewAsKey);
      } else {
        await prefs.setString(_viewAsKey, '${to.lat},${to.lng}');
      }
    } catch (_) {}
  }
  LocationStatus locationStatus = LocationStatus.unknown;

  // --- The town shown at the top of the app -------------------------------
  String? _areaName;
  LatLng? _areaNameAt;
  bool _areaLookupBusy = false;
  int _areaLookupFailedAt = 0;
  static const _areaKey = 'funky.areaName';

  /// The town closest to where the app treats you as being (an admin's
  /// dropped pin counts), e.g. "Somers Point" — the name at the top of the
  /// app. Looked up again whenever you've moved more than a mile; null
  /// until the first lookup comes back.
  String? get areaName {
    final here = location;
    if (here == null) return null;
    final at = _areaNameAt;
    final away = at == null ? double.infinity : milesBetween(at, here);
    if (away > 1) _lookupAreaName(here);
    // Keep showing the last name while a fresh one loads, unless you've
    // jumped somewhere else entirely.
    return away <= 5 ? _areaName : null;
  }

  void _lookupAreaName(LatLng here) {
    if (_areaLookupBusy) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _areaLookupFailedAt < 60000) return;
    _areaLookupBusy = true;
    unawaited(() async {
      final name = await AddressSearch.reverseTown(here.lat, here.lng);
      _areaLookupBusy = false;
      if (name == null) {
        _areaLookupFailedAt = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      _areaName = name;
      _areaNameAt = here;
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_areaKey, '${here.lat},${here.lng},$name');
      } catch (_) {}
    }());
  }

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

  // Guest mode: no account, but a Supabase *anonymous* session so a guest
  // can still see and add to Places, Live Chat and Stories (just not like,
  // message or friend anyone). Needs "Allow anonymous sign-ins" switched on
  // in Supabase → Authentication. signedIn stays false for a guest.
  bool isGuest = false;
  // The random name the server gave this guest ("NeonFox482") — what other
  // people see on a guest's live-chat messages.
  String? guestHandle;
  bool _guestStarting = false;

  /// Why guest browsing couldn't start (anonymous sign-ins switched off in
  /// Supabase, or no connection) — Home shows a sign-in card instead of an
  /// empty feed. Null when it's working or hasn't been tried.
  String? guestUnavailableReason;

  /// True when this phone can talk to the server at all: a real account or a guest.
  bool get canUseServer => (signedIn || isGuest) && supabaseUserId != null;

  /// The name your own live-chat messages show here.
  String get myChatHandle => signedIn ? me.handle : (guestHandle ?? 'guest');

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
      _avatarPending = prefs.getBool(_avatarPendingKey) ?? false;
      await _loadUnreadState(prefs);
      onboardingDone = prefs.getBool(_onboardedKey) ?? false;
      _ageConfirmedAt = prefs.getString(_ageKey);
      ageConfirmed = _ageConfirmedAt != null;
      // Last known town name, so the top of the app isn't blank at launch.
      final area = prefs.getString(_areaKey)?.split(',');
      if (area != null && area.length >= 3) {
        final lat = double.tryParse(area[0]);
        final lng = double.tryParse(area[1]);
        final name = area.sublist(2).join(',').trim();
        if (lat != null && lng != null && name.isNotEmpty) {
          _areaNameAt = LatLng(lat, lng);
          _areaName = name;
        }
      }
      final viewAs = prefs.getString(_viewAsKey)?.split(',');
      if (viewAs != null && viewAs.length == 2) {
        final lat = double.tryParse(viewAs[0]);
        final lng = double.tryParse(viewAs[1]);
        if (lat != null && lng != null) locationOverride = LatLng(lat, lng);
      }
      final savedRadius = prefs.getInt(_radiusKey);
      if (savedRadius != null) _savedRadiusMiles = savedRadius.clamp(minRangeMiles, adminMaxRangeMiles).toInt();
      rangeMiles = (_savedRadiusMiles ?? defaultRangeMiles.round()).clamp(minRangeMiles, maxRangeMiles).toDouble();
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
          // Places are tonight-only too — only a place a FUNKY Admin has
          // verified keeps living across the reset. Anything only the crowd
          // confirmed clears out after 24 hours (see _applyRemotePlaces).
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
      final anonymous = session?.user.isAnonymous ?? false;
      isGuest = session != null && anonymous;
      signedIn = session != null && !anonymous;
      accountEmail = signedIn ? session?.user.email : null;
      supabaseUserId = session?.user.id;
      // Age out old Memories before anyone ever sees them — otherwise the
      // very first frame could flash a Memory that's about to disappear.
      _purgeExpiredMemories();
      await _repairLocalAvatar();
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
      // Admins may have picked a radius past 50 miles.
      _applyRadiusCap();
      if (signedIn || isGuest) {
        _startRemoteSync();
      } else {
        unawaited(_startGuestSession());
      }
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

  /// The phone's last known position, without prompting — a quick fallback
  /// for when the live fix hasn't arrived yet. Null if there isn't one.
  Future<LatLng?> _lastKnownGps() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      final pos = await Geolocator.getLastKnownPosition();
      if (pos == null) return null;
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
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
      _gpsLocation = LatLng(pos.latitude, pos.longitude);
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
    // Only tonight's: a party dated for another night lives under Upcoming
    // until its own night (phase 33).
    final result = places.where((p) => isPlaceOnTonight(p) && near(center, LatLng(p.lat, p.lng))).map((p) => _rank(p, center, allPeople)).toList();
    result.sort((a, b) {
      if (a.heat != b.heat) return b.heat.compareTo(a.heat);
      if (a.going != b.going) return b.going.compareTo(a.going);
      return a.distance.compareTo(b.distance);
    });
    return result;
  }

  RankedPlace _rank(Place p, LatLng center, [Map<String, Person>? everyone]) {
    final allPeople = everyone ?? {...people, 'me': me};
    // Going = everyone headed there tonight, plus anyone who said ahead of
    // time that they'd go (counted once).
    final goingIds = <String>{
      for (final e in allPeople.entries)
        if (e.value.move == p.id) e.key,
      ...?placeRsvps[p.id],
    };
    final going = goingIds.length;
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
  }

  /// Any place by id — tonight's, upcoming, or outside your radius — ranked
  /// from where you are. What a place's own page shows.
  RankedPlace? rankedPlaceById(String id) {
    for (final p in places) {
      if (p.id == id) return _rank(p, location ?? defaultLocation);
    }
    return null;
  }

  /// Whether a place belongs on tonight's lists: an undated spot always
  /// does; a dated party or event only on its own night.
  bool isPlaceOnTonight(Place p) {
    final n = p.night;
    return n == null || n == sessionKey();
  }

  /// Dated for a night after tonight.
  bool isPlaceUpcoming(Place p) {
    final n = p.night;
    return n != null && n.compareTo(sessionKey()) > 0;
  }

  /// Upcoming parties, events, tailgates and frat parties in your area —
  /// anything dated after tonight — soonest first.
  List<RankedPlace> get upcomingPlaces {
    final here = location ?? defaultLocation;
    final everyone = {...people, 'me': me};
    final list = places
        .where((p) => isPlaceUpcoming(p) && near(here, LatLng(p.lat, p.lng)) && !isBanned(p.by))
        .map((p) => _rank(p, here, everyone))
        .toList();
    list.sort((a, b) => a.place.startsAt!.compareTo(b.place.startsAt!));
    return list;
  }

  /// Event posts on a night after tonight, soonest first.
  List<Post> get upcomingEventPosts {
    final today = sessionKey();
    final list = postsNearby.where((p) => p.isEvent && sessionKey(p.eventAt!).compareTo(today) > 0).toList();
    list.sort((a, b) => a.eventAt!.compareTo(b.eventAt!));
    return list;
  }

  /// Event posts happening tonight.
  List<Post> get tonightEventPosts {
    final today = sessionKey();
    final list = postsNearby.where((p) => p.isEvent && sessionKey(p.eventAt!) == today).toList();
    list.sort((a, b) => a.eventAt!.compareTo(b.eventAt!));
    return list;
  }

  /// Events held at a bar or club (trivia, karaoke...), tonight's first,
  /// then upcoming ones.
  List<Place> eventsHostedAt(String placeId) {
    final list = places.where((p) => p.hostPlaceId == placeId && (isPlaceOnTonight(p) || isPlaceUpcoming(p)) && !isBanned(p.by)).toList();
    list.sort((a, b) {
      final at = a.startsAt ?? DateTime.fromMillisecondsSinceEpoch(a.t);
      final bt = b.startsAt ?? DateTime.fromMillisecondsSinceEpoch(b.t);
      return at.compareTo(bt);
    });
    return list;
  }

  /// Tonight's event at a bar or club, if it has one ("Trivia tonight").
  Place? tonightEventAt(String placeId) {
    for (final p in eventsHostedAt(placeId)) {
      if (isPlaceOnTonight(p)) return p;
    }
    return null;
  }

  // --- Going ahead of time (phase 33) ---

  /// Who said they're going to an upcoming place, by place ('me' for you).
  Map<String, Set<String>> placeRsvps = {};

  bool hasRsvped(String placeId) => placeRsvps[placeId]?.contains('me') ?? false;

  /// Your friends who said they're going to [placeId], ahead of time or tonight.
  List<Person> friendsGoingToPlace(String placeId) {
    final friends = me.friends.toSet();
    final ids = <String>{
      ...?placeRsvps[placeId]?.where(friends.contains),
      for (final id in friends)
        if (people[id]?.move == placeId) id,
    };
    return ids.map(personById).whereType<Person>().toList();
  }

  /// Everyone going to [placeId] whose profile is loaded, friends first.
  List<Person> peopleGoingToPlace(String placeId) {
    final ids = <String>{
      ...?placeRsvps[placeId],
      for (final e in people.entries)
        if (e.value.move == placeId) e.key,
      if (me.move == placeId) 'me',
    };
    final friends = me.friends.toSet();
    final list = ids.map((id) => id == 'me' ? me : personById(id)).whereType<Person>().toList();
    list.sort((a, b) => (friends.contains(b.id) ? 1 : 0).compareTo(friends.contains(a.id) ? 1 : 0));
    return list;
  }

  Future<void> _fetchPlaceRsvps() async {
    try {
      final since = DateTime.now().subtract(const Duration(days: 62)).toUtc().toIso8601String();
      final rows = await Supabase.instance.client.from('place_rsvps').select('place_id,user_id').gte('created_at', since);
      final uid = supabaseUserId;
      final next = <String, Set<String>>{};
      for (final r in rows) {
        final pid = r['place_id'] as String?;
        final u = r['user_id'] as String?;
        if (pid == null || u == null) continue;
        (next[pid] ??= <String>{}).add(u == uid ? 'me' : u);
      }
      placeRsvps = next;
      final others = next.values.expand((v) => v).where((u) => u != 'me').toSet();
      if (others.isNotEmpty) await _ensurePeopleFor(others);
      notifyListeners();
    } catch (_) {
      // Phase 33 not run yet, or offline.
    }
  }

  /// "I'm going" on an upcoming party/event (or take it back).
  Future<String?> togglePlaceRsvp(String placeId) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return "Make an account to say you're going.";
    final had = hasRsvped(placeId);
    Map<String, Set<String>> withMine(bool on) {
      final set = {...?placeRsvps[placeId]};
      on ? set.add('me') : set.remove('me');
      return {...placeRsvps, placeId: set};
    }

    placeRsvps = withMine(!had);
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      if (had) {
        await client.from('place_rsvps').delete().eq('place_id', placeId).eq('user_id', uid);
      } else {
        await client.from('place_rsvps').insert({'place_id': placeId, 'user_id': uid});
      }
      return null;
    } catch (e) {
      placeRsvps = withMine(had);
      notifyListeners();
      return _featureError(e, feature: 'Going ahead of time', phase: 'phase 33', fallback: "Couldn't save that");
    }
  }

  List<Poll> get visiblePolls {
    final here = location ?? defaultLocation;
    return polls.where((p) => near(here, LatLng(p.lat, p.lng))).toList();
  }

  /// [visiblePolls], most votes first (newest first on a tie) — Home shows
  /// the top 3 of these, "View all polls" the whole list.
  List<Poll> get rankedVisiblePolls {
    final list = visiblePolls;
    final totals = {for (final p in list) p.id: pollCounts(p).fold<int>(0, (a, b) => a + b)};
    list.sort((a, b) {
      final c = totals[b.id]!.compareTo(totals[a.id]!);
      return c != 0 ? c : b.t.compareTo(a.t);
    });
    return list;
  }

  // Set when the server says you've already posted tonight's poll (e.g.
  // from another phone, or one you since deleted).
  String? _pollUsedSession;

  List<ChatMessage> messagesFor(String room) {
    final list = messages.where((m) => m.room == room).toList();
    list.sort((a, b) => a.t.compareTo(b.t));
    return list;
  }

  /// How long a Story stays up on rings and at places: 24 hours after it
  /// was posted. Older ones only live on as Memories on profiles.
  static const int storyLifetimeMs = 24 * 60 * 60 * 1000;

  bool isLiveStory(Story s) => DateTime.now().millisecondsSinceEpoch - s.t < storyLifetimeMs;

  /// Whether a Story was posted inside your area (your radius around where
  /// you are, or your dropped pin). A place story counts where the place is;
  /// an Area story where the poster was. Your own always count. A story
  /// with no location at all (posted before this was tracked) doesn't.
  bool isStoryNearby(Story s) {
    if (s.uid == 'me') return true;
    double? lat = s.lat;
    double? lng = s.lng;
    final placeId = s.place;
    if (placeId != null && placeId != 'main') {
      for (final p in places) {
        if (p.id == placeId) {
          lat = p.lat;
          lng = p.lng;
          break;
        }
      }
    }
    if (lat == null || lng == null) return false;
    return near(location ?? defaultLocation, LatLng(lat, lng));
  }

  /// Someone's Stories from the last 24 hours, newest first — what their
  /// ring on Home (and the viewer opened from it) shows.
  List<Story> liveStoriesByUser(String uid) => storiesByUser(uid).where(isLiveStory).toList();

  List<Story> get myLiveStories => myStories.where(isLiveStory).toList();

  List<Story> storiesFor(String ring) => stories.where((s) => s.place == ring && isLiveStory(s)).toList();

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
      // Past 24 hours the place goes back to its own default picture.
      if (!isLiveStory(s)) continue;
      // Others' Stories arrive as signed URLs rather than local files —
      // those count too (before, only your own device's media ever did).
      if (s.videoPath == null && s.imagePath == null && s.videoUrl == null && s.imageUrl == null) continue;
      if (latest == null || s.t > latest.t) latest = s;
    }
    return latest;
  }

  Future<void> _fetchBlocks() async {
    final uid = supabaseUserId;
    if (uid == null || isGuest) return;
    try {
      final rows = await Supabase.instance.client.from('blocks').select('blocker_id,blocked_id');
      final mine = <String>{};
      final theirs = <String>{};
      for (final r in rows) {
        final a = r['blocker_id'] as String?;
        final b = r['blocked_id'] as String?;
        if (a == null || b == null) continue;
        if (a == uid) mine.add(b);
        if (b == uid) theirs.add(a);
      }
      _blockedByMe = mine;
      _blockedMe = theirs;
      if (mine.isNotEmpty) await _ensurePeopleFor(mine.toList());
      notifyListeners();
    } catch (_) {
      // Offline, or phase 31 not run yet.
    }
  }

  void _dropFriendshipLocally(String personId) {
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
  }

  /// Blocks [personId]. Returns an error to show, or null.
  Future<String?> blockUser(String personId) async {
    if (!signedIn || supabaseUserId == null) return 'Log in first.';
    try {
      final res = await Supabase.instance.client.rpc('block_user', params: {'p_user': personId}) as String?;
      if (res != null) return res;
    } catch (e) {
      return _featureError(e, feature: 'Blocking', phase: 'phase 31', fallback: "Couldn't block them");
    }
    _blockedByMe = {..._blockedByMe, personId};
    _dropFriendshipLocally(personId);
    notifyListeners();
    _persist();
    return null;
  }

  Future<String?> unblockUser(String personId) async {
    if (!signedIn || supabaseUserId == null) return 'Log in first.';
    try {
      final res = await Supabase.instance.client.rpc('unblock_user', params: {'p_user': personId}) as String?;
      if (res != null) return res;
    } catch (e) {
      return _featureError(e, feature: 'Blocking', phase: 'phase 31', fallback: "Couldn't unblock them");
    }
    _blockedByMe = {..._blockedByMe}..remove(personId);
    notifyListeners();
    return null;
  }

  // --- Delete account (phase 31) -----------------------------------------

  /// Permanently deletes your account and everything in it. Returns an
  /// error to show, or null once it's gone (you're signed out after).
  Future<String?> deleteAccount() async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Not signed in.';
    final client = Supabase.instance.client;
    // Your uploaded photos and videos first (best effort).
    for (final bucket in const ['stories', 'posts', 'dm_media', 'group_media', 'place_covers', 'avatars']) {
      try {
        final files = await client.storage.from(bucket).list(path: uid);
        final paths = [for (final f in files) '$uid/${f.name}'];
        if (paths.isNotEmpty) await client.storage.from(bucket).remove(paths);
      } catch (_) {}
    }
    try {
      final res = await client.rpc('delete_my_account') as String?;
      if (res != null) return res;
    } catch (e) {
      return _featureError(e, feature: 'Deleting your account', phase: 'phase 31', fallback: "Couldn't delete your account");
    }
    // Wipe what this phone kept for that account.
    me = freshMe();
    stories = stories.where((s) => s.uid != 'me').toList();
    messages = messages.where((m) => m.uid != 'me').toList();
    placeReports = placeReports.where((r) => r.reporterId != 'me').toList();
    polls = polls.where((p) => p.by != 'me').toList();
    _appliedBonus = 0;
    _lastUserId = null;
    await signOut();
    return null;
  }

  // --- First run: 21+, terms, onboarding --------------------------------

  static const _onboardedKey = 'funky.onboarded.v1';
  static const _ageKey = 'funky.age21.v1';

  /// The welcome screens have been done on this phone.
  bool onboardingDone = false;

  /// Confirmed 21+ and agreed to the Terms on this phone (or at sign-up).
  bool ageConfirmed = false;
  String? _ageConfirmedAt;

  Future<void> confirmAgeAndTerms() async {
    ageConfirmed = true;
    _ageConfirmedAt ??= DateTime.now().toUtc().toIso8601String();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ageKey, _ageConfirmedAt!);
    } catch (_) {}
    unawaited(_pushAgreement());
  }

  Future<void> completeOnboarding() async {
    onboardingDone = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_onboardedKey, true);
    } catch (_) {}
  }

  /// Saves the 21+ / Terms confirmation on your profile (phase 31).
  Future<void> _pushAgreement() async {
    final uid = supabaseUserId;
    final at = _ageConfirmedAt;
    if (!signedIn || uid == null || at == null) return;
    try {
      await Supabase.instance.client.from('profiles').update({'age_confirmed_at': at, 'terms_accepted_at': at}).eq('id', uid);
    } catch (_) {}
  }

  /// Asks for notification permission (iOS). True if allowed.
  Future<bool> requestNotifications() async {
    if (!Platform.isIOS) return false;
    return PushService.start((token) {
      _pushToken = token;
      if (signedIn) unawaited(_uploadPushToken(token));
    });
  }

  // --- Find friends from contacts (phase 31) -----------------------------

  /// People on FUNKY whose account email is one of [emails] (from your
  /// contacts). Only hashes of the addresses leave the phone.
  Future<List<Person>> matchContacts(Iterable<String> emails) async {
    if (!signedIn || supabaseUserId == null) return const [];
    final hashes = <String>{
      for (final e in emails)
        if (e.trim().contains('@')) crypto.sha256.convert(utf8.encode(e.trim().toLowerCase())).toString(),
    }.take(2000).toList();
    if (hashes.isEmpty) return const [];
    try {
      final rows = await Supabase.instance.client.rpc('match_contacts', params: {'p_hashes': hashes}) as List<dynamic>;
      final ids = <String>[];
      for (final r in rows) {
        if (r is Map && r['id'] is String) ids.add(r['id'] as String);
      }
      if (ids.isEmpty) return const [];
      await _ensurePeopleFor(ids);
      return ids.where((id) => !isHidden(id)).map(personById).whereType<Person>().toList();
    } catch (_) {
      return const [];
    }
  }

  // --- Posts (a few photos + a caption, with likes and comments) ----------

  /// Everyone's posts we've loaded (the newest few hundred), newest first.
  List<Post> posts = [];
  bool postsLoaded = false;
  final Map<String, List<PostComment>> _postComments = {};
  Timer? _postsRefreshTimer;

  static const int maxPostPhotos = 5;
  static const int maxPostCaption = 500;
  static const int maxCommentLength = 300;
  static const int maxPostPhotoBytes = 15 * 1024 * 1024;

  /// Posts inside your radius — everyone's, not just friends' — newest first.
  List<Post> get postsNearby {
    final here = location ?? defaultLocation;
    return posts.where((p) => !isHidden(p.uid) && near(here, LatLng(p.lat, p.lng))).toList();
  }

  /// Someone's posts (newest first) — their profile's Posts tab.
  List<Post> postsBy(String uid) => posts.where((p) => p.uid == uid && !isHidden(p.uid)).toList()..sort((a, b) => b.t.compareTo(a.t));

  /// Posts tagged at [placeId] — that place's page.
  List<Post> postsAt(String placeId) => posts.where((p) => p.placeId == placeId && !isHidden(p.uid)).toList();

  // --- Top posts win points (phase 32) -------------------------------------

  /// The area a post counts toward for the nightly top 3 — the same ~30-mile
  /// grid the server uses (post_region in supabase/phase32.sql).
  static String postRegionOf(double lat, double lng) => '${(lat / 0.45).floor()}:${(lng / 0.55).floor()}';

  static const topPostPoints = [500, 300, 150];

  // Post id → the best place it finished on a past night (1, 2 or 3).
  Map<String, int> _awardRanks = {};
  int? awardRankFor(String postId) => _awardRanks[postId];

  /// Tonight's top 3 posts in your area so far (post id → 1, 2 or 3) — the
  /// ones on track for 500 / 300 / 150 points when the night ends.
  Map<String, int> get tonightTopPosts {
    final here = location ?? defaultLocation;
    final region = postRegionOf(here.lat, here.lng);
    final tonight = sessionKey();
    final list = posts
        .where((p) =>
            !isHidden(p.uid) &&
            p.score >= 1 &&
            postRegionOf(p.lat, p.lng) == region &&
            sessionKey(DateTime.fromMillisecondsSinceEpoch(p.t)) == tonight)
        .toList()
      ..sort((a, b) {
        final c = b.score.compareTo(a.score);
        return c != 0 ? c : a.t.compareTo(b.t);
      });
    return {for (var i = 0; i < list.length && i < 3; i++) list[i].id: i + 1};
  }

  /// Hands out any finished nights' top-post points (the server makes sure
  /// it only happens once), then loads which posts have won.
  Future<void> _awardAndLoadTopPosts() async {
    if (supabaseUserId == null) return;
    final client = Supabase.instance.client;
    try {
      final given = await client.rpc('award_top_posts');
      if (given is int && given > 0) unawaited(_fetchRemoteProfiles());
    } catch (_) {}
    try {
      final since = DateTime.now().subtract(const Duration(days: 60));
      final day = '${since.year}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
      final rows = await client.from('post_awards').select('post_id,rank').gte('night', day);
      final out = <String, int>{};
      for (final r in rows) {
        final id = r['post_id'] as String?;
        final rank = (r['rank'] as num?)?.toInt();
        if (id == null || rank == null) continue;
        final prev = out[id];
        if (prev == null || rank < prev) out[id] = rank;
      }
      _awardRanks = out;
      notifyListeners();
    } catch (_) {
      // Phase 32 not run yet.
    }
  }

  // --- Crash reports (admin, phase 32) --------------------------------------

  List<CrashReport> crashReports = [];
  bool crashReportsLoaded = false;

  Future<void> fetchCrashReports() async {
    if (!isAdmin) {
      crashReportsLoaded = true;
      return;
    }
    try {
      final rows = await Supabase.instance.client.from('crash_reports').select().order('created_at', ascending: false).limit(300);
      crashReports = [
        for (final r in rows)
          CrashReport(
            id: r['id'] as String,
            message: (r['message'] as String?) ?? '',
            stack: r['stack'] as String?,
            context: r['context'] as String?,
            fatal: r['fatal'] as bool? ?? false,
            build: r['build'] as String?,
            platform: r['platform'] as String?,
            userId: r['user_id'] as String?,
            at: DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
          ),
      ];
      crashReportsLoaded = true;
      notifyListeners();
    } catch (_) {
      crashReportsLoaded = true;
      notifyListeners();
    }
  }

  Future<void> clearCrashReports() async {
    if (!isAdmin) return;
    try {
      await Supabase.instance.client.from('crash_reports').delete().lte('created_at', DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
    await fetchCrashReports();
  }

  Post? postById(String id) {
    for (final p in posts) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<PostComment> commentsFor(String postId) => (_postComments[postId] ?? const <PostComment>[]).where((c) => !isHidden(c.uid)).toList();
  bool commentsLoaded(String postId) => _postComments.containsKey(postId);

  String postPhotoUrl(String path) => Supabase.instance.client.storage.from('posts').getPublicUrl(path);

  // What a post row is fetched with. Falls back to the phase-29 shape if
  // phase 30 (dislikes) hasn't been run yet.
  static const _postSelectV31 = '*, post_likes(user_id), post_dislikes(user_id), event_going(user_id), post_comments(count)';
  static const _postSelect = '*, post_likes(user_id), post_dislikes(user_id), post_comments(count)';
  static const _postSelectV29 = '*, post_likes(user_id), post_comments(count)';
  int _postsLevel = 31;
  String get _postColumns => _postsLevel >= 31 ? _postSelectV31 : (_postsLevel == 30 ? _postSelect : _postSelectV29);

  // The newest two comments under each post, oldest first — shown right
  // under it in the feed.
  final Map<String, List<PostComment>> _commentPreviews = {};

  List<PostComment> commentPreviewFor(String postId) {
    final raw = _postComments[postId];
    if (raw != null) {
      final full = raw.where((c) => !isHidden(c.uid)).toList();
      return full.length <= 2 ? full : full.sublist(full.length - 2);
    }
    return (_commentPreviews[postId] ?? const <PostComment>[]).where((c) => !isHidden(c.uid)).toList();
  }

  /// Likes minus dislikes, best first (newest first on a tie) — how every
  /// posts list is ordered.
  List<Post> rankPosts(Iterable<Post> list) {
    final out = list.toList();
    out.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      final l = b.likes.length.compareTo(a.likes.length);
      return l != 0 ? l : b.t.compareTo(a.t);
    });
    return out;
  }

  /// Posts by people you're friends with, from anywhere.
  List<Post> get friendsPosts {
    final friends = me.friends.toSet();
    return posts.where((p) => friends.contains(p.uid) && !isHidden(p.uid)).toList();
  }

  /// The kind of place a post is tagged at, if it's tagged at one we know.
  PlaceKind? postPlaceKind(Post p) {
    final id = p.placeId;
    if (id == null) return null;
    for (final pl in places) {
      if (pl.id == id) return pl.kind;
    }
    return null;
  }

  Post? _postFromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final uid = row['uid'] as String?;
    final lat = (row['lat'] as num?)?.toDouble();
    final lng = (row['lng'] as num?)?.toDouble();
    if (id == null || uid == null || lat == null || lng == null) return null;
    final paths = ((row['photo_paths'] as List?) ?? const []).map((e) => e.toString()).toList();
    final captionText = (row['caption'] as String?) ?? '';
    final eventTitle = row['event_title'] as String?;
    if (paths.isEmpty && captionText.trim().isEmpty && eventTitle == null) return null;
    List<String> voters(Object? raw) {
      final out = <String>[];
      if (raw is List) {
        for (final l in raw) {
          if (l is Map && l['user_id'] is String) out.add(_asMe(l['user_id'] as String));
        }
      }
      return out;
    }
    final likes = voters(row['post_likes']);
    final dislikes = voters(row['post_dislikes']);
    final going = voters(row['event_going']);
    var comments = 0;
    final countRows = row['post_comments'];
    if (countRows is List && countRows.isNotEmpty && countRows.first is Map) {
      comments = ((countRows.first as Map)['count'] as num?)?.toInt() ?? 0;
    }
    final createdAt = DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    return Post(
      id: id,
      uid: _asMe(uid),
      caption: captionText,
      placeId: row['place_id'] as String?,
      placeName: row['place_name'] as String?,
      areaName: row['area_name'] as String?,
      lat: lat,
      lng: lng,
      photoPaths: paths,
      photoUrls: [for (final p in paths) postPhotoUrl(p)],
      t: createdAt.millisecondsSinceEpoch,
      likes: likes,
      dislikes: dislikes,
      commentCount: comments,
      eventTitle: eventTitle,
      eventAt: DateTime.tryParse((row['event_at'] as String?) ?? '')?.toLocal(),
      eventCover: row['event_cover'] as String?,
      going: going,
    );
  }

  /// Events in your area that haven't ended (started less than 6 hours
  /// ago or later), soonest first.
  List<Post> get upcomingEvents {
    final cutoff = DateTime.now().subtract(const Duration(hours: 6));
    final list = postsNearby.where((p) => p.isEvent && p.eventAt!.isAfter(cutoff)).toList();
    list.sort((a, b) => a.eventAt!.compareTo(b.eventAt!));
    return list;
  }

  /// Your friends who said they're going to [post]'s event.
  List<Person> friendsGoingTo(Post post) {
    final friends = me.friends.toSet();
    return post.going.where(friends.contains).map(personById).whereType<Person>().toList();
  }

  /// "I'm going" / not going on an event post.
  Future<String?> toggleEventGoing(String postId) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null || selfBanned) return null;
    final i = posts.indexWhere((p) => p.id == postId);
    if (i == -1) return null;
    final before = posts[i];
    final going = before.going.contains('me');
    posts = [...posts]..[i] = before.copyWith(going: going ? before.going.where((x) => x != 'me').toList() : [...before.going, 'me']);
    notifyListeners();
    try {
      final table = Supabase.instance.client.from('event_going');
      if (going) {
        await table.delete().eq('post_id', postId).eq('user_id', uid);
      } else {
        await table.insert({'post_id': postId, 'user_id': uid});
      }
      return null;
    } catch (e) {
      final j = posts.indexWhere((p) => p.id == postId);
      if (j != -1) {
        posts = [...posts]..[j] = posts[j].copyWith(going: before.going);
        notifyListeners();
      }
      return _featureError(e, feature: 'Events', phase: 'phase 31', fallback: "Couldn't do that");
    }
  }

  void _schedulePostsRefresh() {
    _postsRefreshTimer?.cancel();
    _postsRefreshTimer = Timer(const Duration(milliseconds: 700), () => unawaited(_fetchPosts()));
  }

  void _onRemoteCommentChange(Map<String, dynamic> newRow, Map<String, dynamic> oldRow) {
    _schedulePostsRefresh();
    final postId = (newRow['post_id'] ?? oldRow['post_id']) as String?;
    if (postId != null) {
      if (_postComments.containsKey(postId)) unawaited(fetchComments(postId));
    } else {
      // A delete only carries the comment's id — refresh whatever's open.
      for (final id in _postComments.keys.toList()) {
        unawaited(fetchComments(id));
      }
    }
  }

  /// Pull to refresh on the feed.
  Future<void> refreshPosts() => _fetchPosts();

  Future<void> _fetchPosts() async {
    if (supabaseUserId == null) return;
    final client = Supabase.instance.client;
    final since = DateTime.now().toUtc().subtract(const Duration(days: 60)).toIso8601String();
    // Newest database shape first; falls back if a later phase's SQL
    // hasn't been run yet.
    List<Map<String, dynamic>> rows = const [];
    var ok = false;
    for (final level in const [31, 30, 29]) {
      _postsLevel = level;
      try {
        rows = await client.from('posts').select(_postColumns).gte('created_at', since).order('created_at', ascending: false).limit(300);
        ok = true;
        break;
      } catch (_) {}
    }
    if (!ok) return; // Offline, or phase 29 not run yet.
    final out = <Post>[];
    final ids = <String>{};
    for (final row in rows) {
      final p = _postFromRow(row);
      if (p == null) continue;
      out.add(p);
      if (p.uid != 'me') ids.add(p.uid);
    }
    if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
    // Keep anything older that a profile page pulled in separately.
    final fetched = {for (final p in out) p.id};
    final cutoff = DateTime.now().subtract(const Duration(days: 60)).millisecondsSinceEpoch;
    posts = [...out, ...posts.where((p) => !fetched.contains(p.id) && p.t < cutoff)]..sort((a, b) => b.t.compareTo(a.t));
    postsLoaded = true;
    notifyListeners();
    unawaited(_fetchCommentPreviews(out.where((p) => p.commentCount > 0).map((p) => p.id).toList()));
  }

  Future<void> _fetchCommentPreviews(List<String> postIds) async {
    if (postIds.isEmpty || supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('post_comments')
          .select()
          .inFilter('post_id', postIds.take(150).toList())
          .order('created_at', ascending: false)
          .limit(600);
      final byPost = <String, List<PostComment>>{};
      final ids = <String>{};
      for (final r in rows) {
        final id = r['id'] as String?;
        final postId = r['post_id'] as String?;
        final uid = r['uid'] as String?;
        if (id == null || postId == null || uid == null) continue;
        final list = byPost[postId] ??= [];
        if (list.length >= 2) continue;
        list.add(_commentFromRow(r, postId));
        if (uid != supabaseUserId) ids.add(uid);
      }
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      for (final e in byPost.entries) {
        _commentPreviews[e.key] = e.value.reversed.toList();
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Loads one post (e.g. opened from a notification) if it isn't here yet.
  Future<Post?> ensurePost(String id) async {
    final have = postById(id);
    if (have != null || supabaseUserId == null) return have;
    try {
      final rows = await Supabase.instance.client.from('posts').select(_postColumns).eq('id', id).limit(1);
      if (rows.isEmpty) return null;
      final p = _postFromRow(rows.first);
      if (p == null) return null;
      if (p.uid != 'me') await _ensurePeopleFor([p.uid]);
      posts = [...posts.where((x) => x.id != p.id), p]..sort((a, b) => b.t.compareTo(a.t));
      notifyListeners();
      return p;
    } catch (_) {
      return null;
    }
  }

  /// Every post by [uid] (for their profile), not just the recent ones.
  Future<void> fetchPostsBy(String uid) async {
    final realId = uid == 'me' ? supabaseUserId : uid;
    if (realId == null) return;
    await _fetchPostsWhere('uid', realId);
  }

  /// Every post tagged at [placeId] (for its page).
  Future<void> fetchPostsAt(String placeId) => _fetchPostsWhere('place_id', placeId);

  Future<void> _fetchPostsWhere(String column, String value) async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('posts')
          .select(_postColumns)
          .eq(column, value)
          .order('created_at', ascending: false)
          .limit(200);
      final got = <Post>[];
      for (final row in rows) {
        final p = _postFromRow(row);
        if (p != null) got.add(p);
      }
      final ids = {for (final p in got) p.id};
      final owners = {for (final p in got) if (p.uid != 'me') p.uid};
      if (owners.isNotEmpty) await _ensurePeopleFor(owners.toList());
      posts = [...posts.where((p) => !ids.contains(p.id)), ...got]..sort((a, b) => b.t.compareTo(a.t));
      notifyListeners();
    } catch (_) {}
  }

  // Comment likes and replies came with phase 36; until it's run, comments
  // load the old way.
  bool _commentLikesOk = true;

  PostComment _commentFromRow(Map<String, dynamic> r, String postId) {
    final at = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    final likeRows = r['post_comment_likes'];
    var likes = 0;
    var mine = false;
    if (likeRows is List) {
      likes = likeRows.length;
      mine = likeRows.any((l) => l is Map && l['user_id'] == supabaseUserId);
    }
    return PostComment(
      id: r['id'] as String,
      postId: postId,
      uid: _asMe(r['uid'] as String),
      text: (r['text'] as String?) ?? '',
      t: at.millisecondsSinceEpoch,
      replyTo: r['reply_to'] as String?,
      likes: likes,
      likedByMe: mine,
    );
  }

  Future<void> fetchComments(String postId) async {
    if (supabaseUserId == null) return;
    try {
      List<Map<String, dynamic>> rows;
      if (_commentLikesOk) {
        try {
          rows = await Supabase.instance.client
              .from('post_comments')
              .select('*, post_comment_likes(user_id)')
              .eq('post_id', postId)
              .order('created_at');
        } on PostgrestException {
          _commentLikesOk = false;
          rows = await Supabase.instance.client.from('post_comments').select().eq('post_id', postId).order('created_at');
        }
      } else {
        rows = await Supabase.instance.client.from('post_comments').select().eq('post_id', postId).order('created_at');
      }
      final list = <PostComment>[];
      final ids = <String>{};
      for (final r in rows) {
        final id = r['id'] as String?;
        final uid = r['uid'] as String?;
        if (id == null || uid == null) continue;
        list.add(_commentFromRow(r, postId));
        if (uid != supabaseUserId) ids.add(uid);
      }
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      _postComments[postId] = list;
      final i = posts.indexWhere((p) => p.id == postId);
      if (i != -1 && posts[i].commentCount != list.length) {
        posts = [...posts]..[i] = posts[i].copyWith(commentCount: list.length);
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Uploads the photos and posts them. Returns an error to show, or null.
  Future<String?> createPost({
    required List<String> photoPaths,
    required String caption,
    String? placeId,
    String? eventTitle,
    DateTime? eventAt,
    String? eventCover,
  }) async {
    if (selfBanned) return _bannedMessage;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Log in to post.';
    final paths = photoPaths.take(maxPostPhotos).toList();
    var text = caption.trim();
    if (text.length > maxPostCaption) text = text.substring(0, maxPostCaption);
    var title = eventTitle?.trim();
    if (title != null && title.isEmpty) title = null;
    if (title != null && title.length > 60) title = title.substring(0, 60);
    if (title != null && eventAt == null) return 'Pick when the event starts.';
    var cover = eventCover?.trim();
    if (cover != null && cover.isEmpty) cover = null;
    if (cover != null && cover.length > 20) cover = cover.substring(0, 20);
    if (paths.isEmpty && text.isEmpty && title == null) return 'Add a photo or write something.';
    if (_tooSoon('post', 4000)) return 'Hold on, your post is already going up.';

    String? placeName;
    double? lat;
    double? lng;
    if (placeId != null) {
      for (final p in places) {
        if (p.id == placeId) {
          placeName = p.name;
          lat = p.lat;
          lng = p.lng;
          break;
        }
      }
    }
    // Untagged posts sit where you really are (never an admin's dropped pin).
    if (lat == null || lng == null) {
      final here = _gpsLocation ?? await _lastKnownGps();
      lat = here?.lat;
      lng = here?.lng;
    }
    if (lat == null || lng == null) return 'Turn on location so your post shows up in your area.';

    final client = Supabase.instance.client;
    final uploaded = <String>[];
    try {
      for (var i = 0; i < paths.length; i++) {
        final file = File(paths[i]);
        if (await file.length() > maxPostPhotoBytes) return 'One of those photos is too big (15 MB max).';
        final bytes = await file.readAsBytes();
        final lower = paths[i].toLowerCase();
        final png = lower.endsWith('.png');
        final storagePath = '$uid/${DateTime.now().millisecondsSinceEpoch}_$i.${png ? 'png' : 'jpg'}';
        await client.storage.from('posts').uploadBinary(
              storagePath,
              bytes,
              fileOptions: FileOptions(upsert: false, contentType: png ? 'image/png' : 'image/jpeg'),
            );
        uploaded.add(storagePath);
      }
      // The town, unless an admin is looking at another area right now.
      final town = isViewingElsewhere ? null : _areaName;
      final row = <String, dynamic>{
        'uid': uid,
        'caption': text,
        'place_id': placeId,
        'place_name': placeName,
        'lat': lat,
        'lng': lng,
        'photo_paths': uploaded,
        if (town != null) 'area_name': town.length > 60 ? town.substring(0, 60) : town,
        if (title != null) 'event_title': title,
        if (title != null && eventAt != null) 'event_at': eventAt.toUtc().toIso8601String(),
        if (title != null && cover != null) 'event_cover': cover,
      };
      List<Map<String, dynamic>> rows;
      try {
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => client.from('posts').insert(row).select());
      } on PostgrestException catch (e) {
        // Phase 30 not run yet: no area_name column (and photos required).
        final m = '${e.code} ${e.message}'.toLowerCase();
        if (m.contains('event_')) rethrow;
        if (!m.contains('area_name') && e.code != 'PGRST204') rethrow;
        row.remove('area_name');
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => client.from('posts').insert(row).select());
      }
      final post = _postFromRow(rows.first);
      if (post != null) {
        posts = [post, ...posts.where((p) => p.id != post.id)];
        notifyListeners();
      }
      return null;
    } catch (e) {
      if (uploaded.isNotEmpty) {
        unawaited(() async {
          try {
            await client.storage.from('posts').remove(uploaded);
          } catch (_) {}
        }());
      }
      if (e is PostgrestException && e.message.toLowerCase().contains('rate limit')) {
        return "That's 10 posts today. You can post again tomorrow.";
      }
      if (e is PostgrestException && e.message.toLowerCase().contains('event_')) {
        return "Events need the latest database update (phase 31). Run the new RUN_ALL.sql.";
      }
      return _featureError(e, feature: 'Posts', phase: 'phase 29', fallback: "Couldn't post that");
    }
  }

  /// Like / unlike. Shows right away; undone if the server says no.
  Future<void> togglePostLike(String postId) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null || selfBanned) return;
    final i = posts.indexWhere((p) => p.id == postId);
    if (i == -1) return;
    final before = posts[i];
    final liked = before.likes.contains('me');
    posts = [...posts]
      ..[i] = before.copyWith(
        likes: liked ? before.likes.where((x) => x != 'me').toList() : [...before.likes, 'me'],
        dislikes: before.dislikes.where((x) => x != 'me').toList(),
      );
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      if (liked) {
        await client.from('post_likes').delete().eq('post_id', postId).eq('user_id', uid);
      } else {
        await client.from('post_likes').insert({'post_id': postId, 'user_id': uid});
      }
    } catch (_) {
      final j = posts.indexWhere((p) => p.id == postId);
      if (j != -1) {
        posts = [...posts]..[j] = posts[j].copyWith(likes: before.likes, dislikes: before.dislikes);
        notifyListeners();
      }
    }
  }

  /// Dislike / undo dislike — cancels your like (phase 30).
  Future<String?> togglePostDislike(String postId) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null || selfBanned) return null;
    final i = posts.indexWhere((p) => p.id == postId);
    if (i == -1) return null;
    final before = posts[i];
    final disliked = before.dislikes.contains('me');
    posts = [...posts]
      ..[i] = before.copyWith(
        dislikes: disliked ? before.dislikes.where((x) => x != 'me').toList() : [...before.dislikes, 'me'],
        likes: before.likes.where((x) => x != 'me').toList(),
      );
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      if (disliked) {
        await client.from('post_dislikes').delete().eq('post_id', postId).eq('user_id', uid);
      } else {
        await client.from('post_dislikes').insert({'post_id': postId, 'user_id': uid});
      }
      return null;
    } catch (e) {
      final j = posts.indexWhere((p) => p.id == postId);
      if (j != -1) {
        posts = [...posts]..[j] = posts[j].copyWith(likes: before.likes, dislikes: before.dislikes);
        notifyListeners();
      }
      return _featureError(e, feature: 'Dislikes', phase: 'phase 30', fallback: "Couldn't do that");
    }
  }

  /// Returns an error to show, or null.
  Future<String?> addComment(String postId, String text, {String? replyTo}) async {
    if (selfBanned) return _bannedMessage;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Log in to comment.';
    var clean = text.trim();
    if (clean.isEmpty) return null;
    if (clean.length > maxCommentLength) clean = clean.substring(0, maxCommentLength);
    if (_tooSoon('comment', 1500)) return 'Slow down a sec.';
    try {
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(
          () => Supabase.instance.client.from('post_comments').insert({
                'post_id': postId,
                'uid': uid,
                'text': clean,
                if (replyTo != null) 'reply_to': replyTo,
              }).select());
      final r = rows.first;
      final at = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
      final c = PostComment(id: r['id'] as String, postId: postId, uid: 'me', text: clean, t: at.millisecondsSinceEpoch, replyTo: replyTo);
      final i = posts.indexWhere((p) => p.id == postId);
      final loaded = _postComments[postId];
      if (loaded != null) {
        final list = [...loaded.where((x) => x.id != c.id), c];
        _postComments[postId] = list;
        if (i != -1) posts = [...posts]..[i] = posts[i].copyWith(commentCount: list.length);
      } else {
        // Replied from the feed: just add it to the little preview.
        final prev = [...(_commentPreviews[postId] ?? const <PostComment>[]), c];
        _commentPreviews[postId] = prev.length <= 2 ? prev : prev.sublist(prev.length - 2);
        if (i != -1) posts = [...posts]..[i] = posts[i].copyWith(commentCount: posts[i].commentCount + 1);
      }
      notifyListeners();
      return null;
    } catch (e) {
      if (e is PostgrestException && e.message.toLowerCase().contains('rate limit')) return 'Slow down a sec.';
      if (replyTo != null && e is PostgrestException && e.message.contains('reply_to')) {
        return "Replies aren't switched on yet — the phase 36 database update hasn't been run.";
      }
      return _featureError(e, feature: 'Comments', phase: 'phase 29', fallback: "Couldn't send that comment");
    }
  }

  /// Like or unlike a comment. Returns an error to show, or null.
  Future<String?> toggleCommentLike(PostComment c) async {
    if (selfBanned) return _bannedMessage;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Log in to like comments.';
    if (_tooSoon('comment_like:${c.id}', 400)) return null;
    final liking = !c.likedByMe;
    void apply(bool liked, int likes) {
      final list = _postComments[c.postId];
      if (list != null) {
        _postComments[c.postId] = [for (final x in list) x.id == c.id ? x.copyWith(likes: likes, likedByMe: liked) : x];
      }
      final prev = _commentPreviews[c.postId];
      if (prev != null) {
        _commentPreviews[c.postId] = [for (final x in prev) x.id == c.id ? x.copyWith(likes: likes, likedByMe: liked) : x];
      }
      notifyListeners();
    }

    apply(liking, (c.likes + (liking ? 1 : -1)).clamp(0, 1 << 30));
    try {
      final t = Supabase.instance.client.from('post_comment_likes');
      if (liking) {
        await t.upsert({'comment_id': c.id, 'user_id': uid}, onConflict: 'comment_id,user_id', ignoreDuplicates: true);
      } else {
        await t.delete().eq('comment_id', c.id).eq('user_id', uid);
      }
      return null;
    } catch (e) {
      apply(c.likedByMe, c.likes);
      return _featureError(e, feature: 'Comment likes', phase: 'phase 36', fallback: "Couldn't do that");
    }
  }

  Future<void> deleteComment(PostComment c) async {
    try {
      await Supabase.instance.client.from('post_comments').delete().eq('id', c.id);
    } catch (_) {
      return;
    }
    // Replies to it go with it.
    final list = (_postComments[c.postId] ?? const <PostComment>[]).where((x) => x.id != c.id && x.replyTo != c.id).toList();
    _postComments[c.postId] = list;
    final i = posts.indexWhere((p) => p.id == c.postId);
    if (i != -1) posts = [...posts]..[i] = posts[i].copyWith(commentCount: list.length);
    notifyListeners();
  }

  /// Deletes your own post (or any post, for an admin). Returns an error or null.
  Future<String?> deletePost(String postId) async {
    final p = postById(postId);
    try {
      final rows = await Supabase.instance.client.from('posts').delete().eq('id', postId).select('id');
      if (rows.isEmpty) return "Couldn't delete that post.";
    } catch (e) {
      return _featureError(e, feature: 'Posts', phase: 'phase 29', fallback: "Couldn't delete that post");
    }
    posts = posts.where((x) => x.id != postId).toList();
    _postComments.remove(postId);
    notifyListeners();
    if (p != null) {
      unawaited(() async {
        try {
          await Supabase.instance.client.storage.from('posts').remove(p.photoPaths);
        } catch (_) {}
      }());
    }
    return null;
  }

  /// Flags a post for the admins. Returns a message to show.
  Future<String> reportPost(Post post, String reason) async {
    if (!canUseServer) return 'Sign in to report a post.';
    if (post.uid == 'me') return "That's your own post.";
    if (_tooSoon('postReport', 2000)) return 'One sec…';
    try {
      final res = await Supabase.instance.client.rpc('report_post', params: {'p_post': post.id, 'p_reason': reason}) as String?;
      return res ?? 'Thanks for reporting. The FUNKY team will review it.';
    } catch (e) {
      return _featureError(e, feature: 'Reporting posts', phase: 'phase 29', fallback: "Couldn't send that report");
    }
  }

  // --- Places you've been ("been here" badge) -----------------------------

  // Nights you've been at each place, from the server's place_visits —
  // since phase 37 that's only nights you posted a Story there (tapping
  // "I'm going" doesn't count), from any device.
  Map<String, int> _visitNights = {};

  /// How many different places you've posted a Story at.
  int get placesBeenCount => _visitNights.length;

  /// Whether you've been at [placeId]: posted a Story there (tonight or any
  /// night before).
  bool hasBeenTo(String placeId) {
    if (!signedIn) return false;
    final id = placeId.toLowerCase();
    if ((_visitNights[id] ?? 0) > 0) return true;
    return stories.any((s) => s.uid == 'me' && s.place == placeId);
  }

  /// How many different nights you've posted a Story at [placeId] (0 if never).
  int nightsAt(String placeId) {
    if (!signedIn) return 0;
    final server = _visitNights[placeId.toLowerCase()] ?? 0;
    final local = <String>{
      for (final s in stories)
        if (s.uid == 'me' && s.place == placeId) s.session,
    };
    return server > local.length ? server : local.length;
  }

  // --- Places been: the flex on profiles (phase 37) -------------------------

  final Map<String, PlacesBeen> _placesBeen = {};

  PlacesBeen? placesBeenFor(String personId) => _placesBeen[personId];

  /// Loads someone's places been (yours with 'me'). Friends and you get the
  /// list; anyone else just the count.
  Future<void> fetchPlacesBeen(String personId) async {
    final real = personId == 'me' ? supabaseUserId : personId;
    if (real == null || supabaseUserId == null) return;
    try {
      final res = await Supabase.instance.client.rpc('places_been', params: {'p_user': real});
      if (res is! Map) return;
      final raw = res['places'];
      final list = <PlaceBeen>[];
      if (raw is List) {
        for (final r in raw) {
          if (r is! Map) continue;
          final id = r['id'] as String?;
          if (id == null) continue;
          list.add(PlaceBeen(
            placeId: id,
            name: (r['name'] as String?) ?? 'A spot',
            kind: r['kind'] as String?,
            nights: (r['nights'] as num?)?.toInt() ?? 1,
            last: DateTime.tryParse((r['last'] as String?) ?? ''),
          ));
        }
      }
      _placesBeen[personId] = PlacesBeen(
        count: (res['count'] as num?)?.toInt() ?? 0,
        nights: (res['nights'] as num?)?.toInt() ?? 0,
        places: raw is List ? list : null,
      );
      notifyListeners();
    } catch (_) {
      // Phase 37 not run yet — the profile just skips the section.
    }
  }

  // --- Invites (phase 37) ---------------------------------------------------

  // Who invited you to each place, and who you've invited.
  Map<String, List<String>> _invitesToMe = {};
  Map<String, Set<String>> _invitesSent = {};

  /// Friends who invited you to [placeId] (newest first).
  List<String> invitedBy(String placeId) => (_invitesToMe[placeId] ?? const <String>[]).where((u) => !isHidden(u)).toList();

  bool hasInvited(String placeId, String personId) => _invitesSent[placeId]?.contains(personId) ?? false;

  Future<void> _fetchPlaceInvites() async {
    final uid = supabaseUserId;
    if (uid == null || isGuest) return;
    try {
      final rows = await Supabase.instance.client
          .from('place_invites')
          .select('place_id,from_uid,to_uid')
          .order('created_at', ascending: false)
          .limit(500);
      final toMe = <String, List<String>>{};
      final sent = <String, Set<String>>{};
      final people = <String>{};
      for (final r in rows) {
        final place = r['place_id'] as String?;
        final from = r['from_uid'] as String?;
        final to = r['to_uid'] as String?;
        if (place == null || from == null || to == null) continue;
        if (to == uid) {
          (toMe[place] ??= []).add(from);
          people.add(from);
        }
        if (from == uid) (sent[place] ??= {}).add(to);
      }
      if (people.isNotEmpty) await _ensurePeopleFor(people.toList());
      _invitesToMe = toMe;
      _invitesSent = sent;
      notifyListeners();
    } catch (_) {}
  }

  /// Invites friends to a place. Returns a message to show.
  Future<String> inviteFriendsTo(String placeId, List<String> personIds) async {
    if (!signedIn || supabaseUserId == null) return 'Make an account to invite friends.';
    final ids = personIds.where((p) => p != 'me').toList();
    if (ids.isEmpty) return 'Pick a friend first.';
    try {
      final res = await Supabase.instance.client.rpc('invite_to_place', params: {'p_place': placeId, 'p_to': ids});
      if (res is Map && res['error'] is String) return res['error'] as String;
      final sent = res is Map ? ((res['sent'] as num?)?.toInt() ?? 0) : 0;
      _invitesSent[placeId] = {...?_invitesSent[placeId], ...ids};
      notifyListeners();
      unawaited(_fetchPlaceInvites());
      final p = _placeById(placeId);
      if (p != null && p.isPrivate) unawaited(fetchEventGuests(placeId));
      if (sent == 0) return 'Already invited.';
      return sent == 1 ? 'Invite sent.' : 'Invited $sent friends.';
    } catch (e) {
      return _featureError(e, feature: 'Invites', phase: 'phase 37', fallback: "Couldn't send the invites");
    }
  }

  Place? _placeById(String id) {
    for (final p in places) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Re-checks one private event (e.g. you were just invited to it): its
  /// details if you can see them, your RSVP, and the guest list.
  Future<void> refreshPrivateEvent(String placeId) async {
    final uid = supabaseUserId;
    if (uid == null || !_privateEventsOk) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('private_event_details').select().eq('place_id', placeId).limit(1);
      final mine = await client.from('event_guests').select('status').eq('place_id', placeId).eq('user_id', uid).limit(1);
      if (rows.isNotEmpty) {
        _privateDetails[placeId] = _detailsFromRow(rows.first);
        _applyPrivateToPlace(placeId);
      }
      if (mine.isNotEmpty) _myEventStatus[placeId] = (mine.first['status'] as String?) ?? 'unlocked';
      notifyListeners();
      if (rows.isNotEmpty) await fetchEventGuests(placeId);
    } catch (_) {}
  }

  Future<void> _fetchPlaceVisits() async {
    final uid = supabaseUserId;
    if (uid == null || isGuest) return;
    try {
      final rows = await Supabase.instance.client.from('place_visits').select('place_id,night').eq('user_id', uid);
      final out = <String, int>{};
      for (final r in rows) {
        final id = (r['place_id'] as String?)?.toLowerCase();
        if (id == null) continue;
        out[id] = (out[id] ?? 0) + 1;
      }
      _visitNights = out;
      if (_placesBeen.containsKey('me')) unawaited(fetchPlacesBeen('me'));
      notifyListeners();
    } catch (_) {
      // Offline, or phase 27 not run yet — the local guess still works.
    }
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
  ///
  /// Text-only Stories are never memories — they live for their 24 hours
  /// as a Story and that's it. Only photos and videos are kept.
  List<Story> visibleStoriesByUser(String uid) {
    final theirs = storiesByUser(uid).where(isMemoryStory).toList();
    if (canSeeStoriesOf(uid)) return theirs;
    final today = sessionKey();
    return theirs.where((s) => s.session == today).toList();
  }

  /// Whether a Story counts as a Memory: it has a photo or video. A
  /// text-only Story is just a 24-hour Story.
  bool isMemoryStory(Story s) =>
      s.imagePath != null || s.imageUrl != null || s.videoPath != null || s.videoUrl != null || s.mediaPath != null;

  /// Your Memories (photos and videos you've posted), newest first.
  List<Story> get myMemories => myStories.where(isMemoryStory).toList();

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
    final localMatches = people.values.where((p) => p.handle.toLowerCase().contains(q) && !isHidden(p.id)).toList();
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
        if (isHidden(id)) continue;
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
      return ids.where((id) => !isHidden(id)).map(personById).whereType<Person>().toList();
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
    _avatarBackfillTried = false;
    await _setAvatarPending(true);
    return _uploadAvatar(path);
  }

  bool _avatarBackfillTried = false;
  static const _avatarPendingKey = 'funky.avatarPending';
  bool _avatarPending = false;
  bool _avatarUploading = false;

  /// Your picture is remembered as a path inside the app's own folder — but
  /// that folder's address can change (an app update, a restore) and the OS
  /// can clean files up, which is what made your picture "reset" to a letter
  /// even though the uploaded copy was fine. If the file isn't where we left
  /// it, look for it in the current folder; failing that, drop the dead path
  /// so the uploaded picture (photoUrl) shows instead.
  Future<void> _repairLocalAvatar() async {
    final path = me.photoPath;
    if (path == null) return;
    try {
      if (File(path).existsSync()) return;
      final marker = '/Documents/';
      final i = path.indexOf(marker);
      if (i >= 0) {
        final docs = await getApplicationDocumentsDirectory();
        final moved = '${docs.path}/${path.substring(i + marker.length)}';
        if (File(moved).existsSync()) {
          me = me.copyWith(photoPath: moved);
          return;
        }
      }
      me = me.copyWith(clearPhotoPath: true);
    } catch (_) {}
  }

  Future<void> _setAvatarPending(bool v) async {
    _avatarPending = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_avatarPendingKey, v);
    } catch (_) {}
  }

  /// Uploads your profile picture to the public avatars bucket and points
  /// your profile row at it, so everyone else sees it (their app can only
  /// show an image by URL — your local file path means nothing to them).
  Future<String?> _uploadAvatar(String path) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return null;
    _avatarUploading = true;
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
      // Show the uploaded copy right away too, so if the local file ever
      // goes missing the picture is still there.
      me = me.copyWith(photoUrl: busted);
      notifyListeners();
      _persist();
      await _setAvatarPending(false);
      return null;
    } catch (e) {
      // Your own device keeps showing the local file either way, but other
      // people can't see it until this works — so say why.
      return "Your picture saved on this phone but couldn't upload for other people — ${_friendlySendError(e)}";
    } finally {
      _avatarUploading = false;
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
  bool get canAddPollToday =>
      isAdmin || (_pollUsedSession != sessionKey() && !polls.any((p) => p.by == 'me' && p.session == sessionKey()));

  // Lowercased, letters/digits-only — so "Sigma Chi", "sigma-chi!", and
  // "Sigma  Chi" all collapse to the same key before comparing names.
  String _normalizedPlaceName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// The existing place within the 25-mile radius (same radius
  /// [rankedPlacesFrom] uses — "nearby" always means the same thing) whose
  /// name looks like a duplicate of [name], or null if there isn't one.
  /// Lets the Add Place form warn before you even try to submit, and
  /// backstops [addPlace] itself in case something slips past that check.
  Place? similarNearbyPlace(String name, {LatLng? at, String? night, String? ignoreId}) {
    final target = _normalizedPlaceName(name);
    if (target.isEmpty) return null;
    final here = at ?? location ?? defaultLocation;
    for (final p in places) {
      if (p.id == ignoreId || !near(here, LatLng(p.lat, p.lng))) continue;
      // A dated party/event only clashes with one on the same night (the
      // same trivia night can be added every week).
      final pn = p.night;
      if (night != null) {
        if (pn != night) continue;
      } else if (pn != null && pn != sessionKey()) {
        continue;
      }
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
  Future<Place?> addPlace(String name, PlaceKind kind, String address,
      {String? coverPhotoPath,
      LatLng? at,
      DateTime? startsAt,
      String? eventType,
      String? hostPlaceId,
      bool isPrivate = false,
      String? passcode}) async {
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
    if (similarNearbyPlace(cleanName, at: at, night: startsAt == null ? null : sessionKey(startsAt), ignoreId: hostPlaceId) != null) return null;
    final uid = supabaseUserId;
    if (!canUseServer || uid == null) {
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
    // A private event's public row only has a rough spot (about half a mile),
    // a placeholder address and just the night; the real ones go in
    // private_event_details for people with the code.
    final code = passcode?.trim() ?? '';
    final private = isPrivate && code.length >= 3;
    DateTime? publicStart = startsAt;
    if (private && startsAt != null) {
      final n = sessionKey(startsAt);
      final day = DateTime.tryParse(n);
      publicStart = n == sessionKey() || day == null ? null : DateTime(day.year, day.month, day.day, 21);
    }
    double rough(double v) => (v * 100).roundToDouble() / 100;
    // Places are shared, so this goes straight to the server and waits for
    // its real id (the same id everyone else will see) before showing up.
    Place place;
    try {
      Future<List<Map<String, dynamic>>> insertPlace(bool withCover) {
        return _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('places').insert({
              'name': cleanName,
              'kind': kind.name,
              'lat': private ? rough(here.lat) : here.lat,
              'lng': private ? rough(here.lng) : here.lng,
              'address': private ? 'Private event' : cleanAddress,
              if (private) 'is_private': true,
              'by_uid': uid,
              // Only the admin's insert policy accepts a pre-verified place; for
              // everyone else this is just false.
              'admin_verified': isAdmin,
              if (withCover && coverUrl != null) 'cover_url': coverUrl,
              // Phase 33: a date, what kind of event, and the bar it's at.
              if (publicStart != null) 'starts_at': publicStart.toUtc().toIso8601String(),
              if (eventType != null) 'event_type': eventType,
              if (hostPlaceId != null) 'host_place_id': hostPlaceId,
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
        startsAt: built.startsAt,
        eventType: built.eventType,
        hostPlaceId: built.hostPlaceId,
        isPrivate: built.isPrivate,
        timeHidden: built.timeHidden,
      );
    } catch (e) {
      final m = e.toString();
      if (private && m.contains('is_private')) {
        lastPlaceError = "Private events aren't switched on yet — run RUN_ALL.sql (phase 36) in Supabase.";
        return null;
      }
      if ((startsAt != null || eventType != null || hostPlaceId != null) &&
          (m.contains('starts_at') || m.contains('event_type') || m.contains('host_place_id'))) {
        lastPlaceError = "Dates and events at bars aren't switched on yet — run RUN_ALL.sql (phase 33) in Supabase.";
        return null;
      }
      final why = _friendlySendError(e);
      lastPlaceError = why.startsWith('No connection') ? "Couldn't add that place — check your connection and try again." : "Couldn't add that place — $why";
      return null;
    }
    if (private) {
      final client = Supabase.instance.client;
      try {
        await client.from('private_event_details').insert({
          'place_id': place.id,
          'address': cleanAddress,
          'lat': here.lat,
          'lng': here.lng,
          if (startsAt != null) 'starts_at': startsAt.toUtc().toIso8601String(),
          'passcode': code,
        });
        await client.from('event_guests').insert({'place_id': place.id, 'user_id': uid, 'status': 'going'});
      } catch (e) {
        // The secret half didn't save — take the event back down rather
        // than leave a private party nobody can get into.
        try {
          await client.from('places').delete().eq('id', place.id);
        } catch (_) {}
        lastPlaceError = _featureError(e, feature: 'Private events', phase: 'phase 36', fallback: "Couldn't make it private");
        return null;
      }
      final d = PrivateEventDetails(placeId: place.id, address: cleanAddress, lat: here.lat, lng: here.lng, startsAt: startsAt, passcode: code);
      _privateDetails[place.id] = d;
      _myEventStatus[place.id] = 'going';
      place = _withPrivate(place, d);
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
      lastPollError = "You can only post one poll a day — check back after the 2 PM reset.";
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
      // The server's one-poll-a-day rule (phase 28).
      if (e is PostgrestException && e.message.toLowerCase().contains('one poll a day')) {
        _pollUsedSession = sessionKey();
        lastPollError = "You can only post one poll a day — check back after the 2 PM reset.";
        notifyListeners();
        return null;
      }
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
  String? sendMessage(String room, String text, bool anon, {ChatMessage? replyTo, String? placeId, String? pollId, String? gifUrl}) {
    if (selfBanned) return _bannedMessage;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastMessageAt;
    if (last != null && now - last < _messageCooldownMs) {
      return 'Slow down a sec before sending another message.';
    }
    final capped = text.length > _maxMessageLength ? text.substring(0, _maxMessageLength) : text;
    final hasExtra = placeId != null || pollId != null || gifUrl != null;
    if (capped.trim().isEmpty && !hasExtra) return null;
    // Guests can only chat anonymously (the server insists too).
    final asAnon = anon || (isGuest && !signedIn);
    final here = location;
    String? replyHandle;
    String? replyText;
    if (replyTo != null) {
      replyHandle = replyTo.anon ? 'anonymous' : chatHandleFor(replyTo);
      final words = replyTo.text.trim().isNotEmpty
          ? replyTo.text.trim()
          : (replyTo.gifUrl != null ? 'GIF' : (replyTo.sharedPlaceId != null ? 'Shared a spot' : (replyTo.pollId != null ? 'Shared a poll' : '')));
      replyText = words.length > 120 ? '${words.substring(0, 117)}...' : words;
    }
    final message = ChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      t: DateTime.now().millisecondsSinceEpoch,
      room: room,
      uid: 'me',
      text: capped.trim().isEmpty ? '' : capped,
      anon: asAnon,
      status: room == 'main' && canUseServer ? 'sending' : 'delivered',
      lat: room == 'main' ? here?.lat : null,
      lng: room == 'main' ? here?.lng : null,
      reachMiles: room == 'main' ? rangeMiles.round() : null,
      replyToId: replyTo != null && !replyTo.id.startsWith('msg_') ? replyTo.id : null,
      replyText: replyText,
      replyHandle: replyHandle,
      sharedPlaceId: placeId,
      pollId: pollId,
      gifUrl: gifUrl,
    );
    messages = _capMessages([...messages, message]);
    _lastMessageAt = now;
    notifyListeners();
    _persist();
    if (room == 'main' && canUseServer) {
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
      final payload = <String, dynamic>{
            // Anonymous messages carry NO sender at all (see the SQL) — the
            // server keeps the real author in an admin-only table.
            'sender_id': local.anon ? null : uid,
            'text': local.text,
            'anon': local.anon,
            'lat': local.lat,
            'lng': local.lng,
            // Phase 33 extras — only sent when used, so plain messages still
            // work before that SQL is run.
            if (local.replyToId != null) 'reply_to': local.replyToId,
            if (local.replyText != null) 'reply_text': local.replyText,
            if (local.replyHandle != null) 'reply_handle': local.replyHandle,
            if (local.sharedPlaceId != null) 'place_id': local.sharedPlaceId,
            if (local.pollId != null) 'poll_id': local.pollId,
            if (local.gifUrl != null) 'gif_url': local.gifUrl,
            if (local.reachMiles != null) 'reach_miles': local.reachMiles,
      };
      List<Map<String, dynamic>> rows;
      try {
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('chat_messages').insert(payload).select());
      } on PostgrestException catch (e) {
        // reach_miles comes with phase 35 — send without it until then.
        if (!'${e.message} ${e.details}'.contains('reach_miles')) rethrow;
        payload.remove('reach_miles');
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => Supabase.instance.client.from('chat_messages').insert(payload).select());
      }
      final serverId = rows.first['id'] as String;
      _remoteChatIds.add(serverId);
      messages = messages
          .where((m) => m.id != serverId)
          .map((m) => m.id == local.id ? m.copyWith(id: serverId, status: 'sent') : m)
          .toList();
    } catch (e) {
      final em = e.toString();
      final extrasMissing = em.contains('reply_') || em.contains('place_id') || em.contains('poll_id') || em.contains('gif_url') || em.contains('chat_messages_text_check');
      _sendErrors[local.id] = extrasMissing
          ? 'Replies, spots, polls and GIFs need the latest database update (RUN_ALL.sql, phase 33).'
          : _friendlySendError(e);
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
    if (i == -1 || !canUseServer) return;
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
  ///
  /// [replyTo] is the Story you swiped up on, if any — the message carries a
  /// small snapshot of it (caption + the picture's storage path) so the
  /// thread can show what you were replying to.
  Future<String?> sendDirectMessage(String toPersonId, String text,
      {String? mediaPath, String? mediaType, bool skipCooldown = false, Story? replyTo, String? gifUrl}) async {
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
    if (capped.trim().isEmpty && !hasMedia && gifUrl == null) return null;
    if (hasMedia) {
      if (!skipCooldown && _tooSoon('dmMedia', 5000)) return 'Slow down — one snap every few seconds.';
      try {
        final bytes = await File(mp).length();
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
      storyId: replyTo?.id,
      storyText: replyTo == null ? null : _storyReplyCaption(replyTo),
      storyMediaPath: replyTo?.mediaPath,
      storyIsVideo: replyTo != null && (replyTo.videoUrl != null || replyTo.videoPath != null),
      gifUrl: gifUrl,
    );
    if (replyTo != null) _storyReplySnapshots[local.id] = replyTo;
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
      final base = <String, dynamic>{
        'sender_id': uid,
        'recipient_id': toPersonId,
        'text': local.text,
        if (storagePath != null) 'media_path': storagePath,
        if (storagePath != null) 'media_type': local.mediaType,
        if (local.gifUrl != null) 'gif_url': local.gifUrl,
      };
      final storyCols = <String, dynamic>{
        if (local.storyId != null && _looksLikeUuid(local.storyId!)) 'story_id': local.storyId,
        if (local.storyText != null) 'story_text': local.storyText,
        if (local.storyMediaPath != null) 'story_media_path': local.storyMediaPath,
        if (local.isStoryReply) 'story_is_video': local.storyIsVideo,
      };
      List<Map<String, dynamic>> rows;
      try {
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(
            () => client.from('messages').insert({...base, ...storyCols}).select());
      } on PostgrestException catch (e) {
        // Server hasn't run phase25 yet (no story_* columns) — still send
        // the message itself, just without the Story preview attached.
        final msg = e.message.toLowerCase();
        final missingCol = storyCols.isNotEmpty && (e.code == 'PGRST204' || e.code == '42703' || msg.contains('story_'));
        if (!missingCol) rethrow;
        rows = await _withProfileRepair<List<Map<String, dynamic>>>(() => client.from('messages').insert(base).select());
      }
      final serverId = rows.first['id'] as String;
      _remoteMessageIds.add(serverId);
      final snap = _storyReplySnapshots.remove(local.id);
      if (snap != null) _storyReplySnapshots[serverId] = snap;
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
    final partners = lastByPartner.keys.map(personById).whereType<Person>().where((p) => !isHidden(p.id)).toList();
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

    // Where you really are right now (never an admin's dropped pin) — keeps
    // an Area story inside the area it was posted in. If GPS hasn't come in
    // yet, the phone's last known fix is used; failing that the server
    // fills it in from the venue or your last synced spot (phase 26).
    final here = _gpsLocation ?? await _lastKnownGps();
    // A photo or video posted at a place saves itself to your Memories (it
    // won't delete after memoryRetentionDays).
    final atPlaceWithMedia = place != 'main' && (imagePath != null || videoPath != null);
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
        final row = <String, dynamic>{
          'uid': uid,
          'text': text,
          'place_id': place == 'main' ? null : place,
          'place_name': placeName,
          'anon': anon,
          'media_path': mediaPath,
          'is_video': videoPath != null,
          // A photo or video posted at a place is kept as a Memory for good.
          if (atPlaceWithMedia) 'saved_to_timeline': true,
          if (here != null) 'lat': here.lat,
          if (here != null) 'lng': here.lng,
        };
        List<Map<String, dynamic>> rows;
        try {
          rows = await client.from('stories').insert(row).select();
        } on PostgrestException catch (e) {
          // The lat/lng columns arrive with phase 24 — post without them
          // until that SQL has been run.
          final m = '${e.code} ${e.message}'.toLowerCase();
          if (!(m.contains('lat') || m.contains('lng') || m.contains('pgrst204'))) rethrow;
          row
            ..remove('lat')
            ..remove('lng');
          rows = await client.from('stories').insert(row).select();
        }
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
      lat: here?.lat,
      lng: here?.lng,
      savedToTimeline: atPlaceWithMedia,
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
    if (i == -1 || !isMemoryStory(stories[i])) return;
    final updated = [...stories];
    updated[i] = updated[i].copyWith(savedToTimeline: true);
    stories = updated;
    notifyListeners();
    _persist();
    _syncSaved(storyId, true);
  }

  /// Saving or un-saving goes to the server too, which is what deletes
  /// unsaved Memories after memoryRetentionDays (phase 38) — and keeps the
  /// choice when you switch phones.
  void _syncSaved(String storyId, bool saved) {
    final uid = supabaseUserId;
    if (!signedIn || uid == null || !_remoteStoryIds.contains(storyId)) return;
    _fireAndForgetRemote(
      () => Supabase.instance.client.from('stories').update({'saved_to_timeline': saved}).eq('id', storyId).eq('uid', uid),
    );
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
    _syncSaved(storyId, false);
  }

  /// Drops your own Stories once they're older than memoryRetentionDays,
  /// unless they've been explicitly saved to your Timeline. Run once per
  /// load() — everyone else's Stories are already handled by the normal
  /// 2 PM session reset elsewhere, so this only ever looks at 'me'.
  void _purgeExpiredMemories() {
    final cutoff = DateTime.now().subtract(const Duration(days: memoryRetentionDays)).millisecondsSinceEpoch;
    stories = stories.where((s) {
      if (s.uid != 'me') return true;
      // Text-only Stories never become Memories: gone after their 24 hours.
      if (!isMemoryStory(s)) return isLiveStory(s);
      return s.savedToTimeline || s.t >= cutoff;
    }).toList();
  }

  /// Deletes unsaved Memories older than memoryRetentionDays on the server
  /// (everyone's — whoever opens the app first does it), then removes your
  /// own deleted Stories' files from Storage (an admin's app removes
  /// anyone's). Needs phase 38; quietly does nothing before that.
  Future<void> _purgeExpiredMemoriesRemote() async {
    if (supabaseUserId == null || !signedIn) return;
    final client = Supabase.instance.client;
    try {
      await client.rpc('purge_expired_memories');
    } catch (_) {
      return;
    }
    try {
      final rows = await client.from('storage_trash').select('id,bucket,path').limit(300);
      if (rows.isEmpty) return;
      final byBucket = <String, Map<String, int>>{};
      for (final r in rows) {
        final id = (r['id'] as num?)?.toInt();
        final bucket = r['bucket'] as String?;
        final path = r['path'] as String?;
        if (id == null || bucket == null || path == null) continue;
        (byBucket[bucket] ??= {})[path] = id;
      }
      final done = <int>[];
      for (final e in byBucket.entries) {
        try {
          final removed = await client.storage.from(e.key).remove(e.value.keys.toList());
          final names = removed.map((f) => f.name).toSet();
          for (final p in e.value.entries) {
            if (names.contains(p.key)) done.add(p.value);
          }
        } catch (_) {}
      }
      if (done.isNotEmpty) await client.from('storage_trash').delete().inFilter('id', done);
    } catch (_) {}
    unawaited(_fetchRemoteStories());
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
    if (canUseServer && _remoteStoryIds.contains(storyId)) {
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
    if (canUseServer && _remotePlaceIds.contains(placeId)) {
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
    if (canUseServer && uid != null && _remoteReportIds.contains(reportId)) {
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
      if (data.event == AuthChangeEvent.signedIn && s != null && !signedIn && !s.user.isAnonymous) {
        _leaveGuest();
        accountEmail = s.user.email;
        supabaseUserId = s.user.id;
        signedIn = true;
        _applyRadiusCap();
        notifyListeners();
        _persist();
        _startRemoteSync();
      }
    });
  }

  Future<String?> signUp(String email, String password, {bool agreedAge21AndTerms = false}) async {
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
        data: agreedAge21AndTerms ? {'age_21_confirmed': true, 'terms_accepted_at': DateTime.now().toUtc().toIso8601String()} : null,
      );
      if (agreedAge21AndTerms) unawaited(confirmAgeAndTerms());
      if (response.session == null) {
        return 'Check your email to confirm your account, then log in.';
      }
      _leaveGuest();
      accountEmail = response.user?.email;
      supabaseUserId = response.user?.id;
      signedIn = true;
      _applyRadiusCap();
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
      _leaveGuest();
      accountEmail = response.user?.email;
      supabaseUserId = response.user?.id;
      signedIn = true;
      _applyRadiusCap();
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
    _applyRadiusCap();
    notifyListeners();
    _persist();
    // Keep browsing as a guest (places, live chat, stories).
    unawaited(_startGuestSession());
  }

  /// Opens a guest (anonymous) session so someone without an account can
  /// still use Places, Live Chat and Stories. Quietly does nothing if
  /// anonymous sign-ins are switched off in Supabase or the phone is offline.
  Future<void> _startGuestSession() async {
    if (signedIn || isGuest || _guestStarting) return;
    _guestStarting = true;
    try {
      final res = await Supabase.instance.client.auth.signInAnonymously();
      final s = res.session;
      if (s == null || signedIn) return;
      isGuest = true;
      guestUnavailableReason = null;
      supabaseUserId = s.user.id;
      notifyListeners();
      _startRemoteSync();
    } catch (e) {
      // Anonymous sign-ins are off in Supabase, or no connection.
      final text = e.toString().toLowerCase();
      guestUnavailableReason = text.contains('anonymous') || text.contains('disabled')
          ? 'Guest browsing is switched off.'
          : 'No connection.';
      notifyListeners();
    } finally {
      _guestStarting = false;
    }
  }

  /// Drops the guest session's data the moment a real account takes over.
  void _leaveGuest() {
    if (!isGuest) return;
    _stopRemoteSync();
    _clearRemoteData();
    isGuest = false;
    guestHandle = null;
    supabaseUserId = null;
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
  RealtimeChannel? _storyReportsChannel;
  RealtimeChannel? _postsChannel;
  RealtimeChannel? _blocksChannel;
  RealtimeChannel? _groupMessagesChannel;
  RealtimeChannel? _groupsChannel;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _chatReactionsChannel;
  RealtimeChannel? _friendshipsChannel;
  RealtimeChannel? _profilesChannel;
  RealtimeChannel? _callsChannel;
  RealtimeChannel? _groupCallsChannel;
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
    final guest = isGuest;
    // A guest session never takes over (or wipes) this phone's own account data.
    if (!guest) _resetLocalIfDifferentAccount(uid);
    unawaited(_fetchRemoteProfiles());
    unawaited(_fetchRemotePlaces(purge: true));
    if (!guest) unawaited(_purgeExpiredMemoriesRemote());
    unawaited(_fetchPlaceRatings());
    unawaited(_fetchRemoteChat());
    unawaited(_fetchRemotePolls());
    unawaited(_fetchRemoteReports());
    unawaited(_fetchRemoteStories());
    unawaited(_fetchPosts());
    unawaited(_awardAndLoadTopPosts());
    unawaited(_fetchPlaceRsvps());
    unawaited(_fetchAppConfig());
    unawaited(_pingPresence());
    if (!guest) {
      unawaited(_fetchRemoteFriendships());
      unawaited(_fetchPhotoSuggestions());
      unawaited(_fetchProfileReports());
      unawaited(_fetchStoryReports());
      unawaited(_fetchPlaceVisits());
      unawaited(_fetchPlaceInvites());
      unawaited(_fetchBlocks());
      unawaited(_pushAgreement());
      unawaited(_fetchGroups());
      unawaited(refreshGroupCalls());
      unawaited(fetchCallLog());
      unawaited(fetchGroupCallLog());
      unawaited(_fetchRemoteMessages());
      unawaited(_fetchNotifications());
      unawaited(_fetchNotifPrefs());
      unawaited(_registerPush());
    }

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

    _postsChannel = client.channel('public:posts:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'posts',
        callback: (_) => _schedulePostsRefresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'post_likes',
        callback: (_) => _schedulePostsRefresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'post_dislikes',
        callback: (_) => _schedulePostsRefresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'event_going',
        callback: (_) => _schedulePostsRefresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'post_comments',
        callback: (payload) => _onRemoteCommentChange(payload.newRecord, payload.oldRecord),
      )
      ..subscribe();

    _blocksChannel = client.channel('public:blocks:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'blocks',
        callback: (_) => unawaited(_fetchBlocks()),
      )
      ..subscribe();

    _storyReportsChannel = client.channel('public:story_reports:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'story_reports',
        callback: (_) => unawaited(_fetchStoryReports()),
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

    // A friend ringing you (RLS only lets you see calls you're part of).
    _callsChannel = client.channel('public:calls:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'calls',
        callback: (payload) => _onCallRow(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'calls',
        callback: (payload) => _onCallRow(payload.newRecord),
      )
      ..subscribe();

    // A group started (or ended) a video call.
    _groupCallsChannel = client.channel('public:group_calls:sync')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_calls',
        callback: (_) => _scheduleGroupCallRefresh(),
      )
      ..subscribe();

    // Who's online right now (the green dot in Messages). Only real
    // accounts announce themselves; guests just aren't shown.
    if (!guest) _startPresence(client, uid);
  }

  // --- Friend counts (profiles) ------------------------------------------

  /// How many friends someone has, for the number on their profile —
  /// fetched from the server's count-only friend_count function.
  final Map<String, int> friendCounts = {};

  Future<void> loadFriendCount(String personId) async {
    if (personId == 'me' || !_isRealPersonId(personId) || supabaseUserId == null) return;
    try {
      final n = await Supabase.instance.client.rpc('friend_count', params: {'p_user': personId});
      if (n is num && friendCounts[personId] != n.toInt()) {
        friendCounts[personId] = n.toInt();
        notifyListeners();
      }
    } catch (_) {
      // Offline, or phase 17 not run yet — the profile just shows "–".
    }
  }

  // --- Online status -------------------------------------------------------

  RealtimeChannel? _presenceChannel;

  /// Ids of people whose app is open right now.
  Set<String> onlineIds = {};

  bool isOnline(String personId) => personId != 'me' && onlineIds.contains(personId);

  void _startPresence(SupabaseClient client, String uid) {
    final channel = client.channel('online_users');
    channel.onPresenceSync((_) {
      final next = <String>{};
      try {
        for (final state in channel.presenceState()) {
          for (final presence in state.presences) {
            final id = presence.payload['uid'];
            if (id is String && id != uid) next.add(id);
          }
        }
      } catch (_) {}
      if (next.length != onlineIds.length || !next.containsAll(onlineIds)) {
        onlineIds = next;
        notifyListeners();
      }
    });
    channel.subscribe((status, error) async {
      if (status != RealtimeSubscribeStatus.subscribed) return;
      try {
        await channel.track({'uid': uid});
      } catch (_) {}
    });
    _presenceChannel = channel;
  }

  // --- Unread messages -----------------------------------------------------

  // room -> when you last had that DM/group thread open (ms). Messages from
  // other people after that count as unread. Anything from before this
  // phone started tracking (_unreadBaseline) is treated as already read.
  final Map<String, int> _threadReadAt = {};
  int _unreadBaseline = 0;
  static const _threadReadKey = 'funky.threadReadAt';
  static const _unreadBaselineKey = 'funky.unreadBaseline';

  Future<void> _loadUnreadState(SharedPreferences prefs) async {
    var baseline = prefs.getInt(_unreadBaselineKey);
    if (baseline == null) {
      baseline = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(_unreadBaselineKey, baseline);
    }
    _unreadBaseline = baseline;
    final raw = prefs.getString(_threadReadKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          final v = e.value;
          if (v is num) _threadReadAt[e.key] = v.toInt();
        }
      } catch (_) {}
    }
  }

  /// How many messages from other people in [room] you haven't seen yet.
  int unreadCountFor(String room) {
    final since = math.max(_unreadBaseline, _threadReadAt[room] ?? 0);
    var n = 0;
    for (final m in messages) {
      if (m.room == room && m.uid != 'me' && m.t > since) n++;
    }
    return n;
  }

  /// Unread messages across every DM and group thread — the Chat tab badge.
  int get totalUnreadMessages {
    var n = 0;
    for (final p in dmConversations) {
      n += unreadCountFor(dmRoomId('me', p.id));
    }
    for (final g in groups) {
      n += unreadCountFor(g.room);
    }
    return n;
  }

  /// Call while a DM/group thread is open: everything in it counts as read.
  void markThreadRead(String room) {
    final hadUnread = unreadCountFor(room) > 0;
    _threadReadAt[room] = DateTime.now().millisecondsSinceEpoch;
    if (!hadUnread) return;
    notifyListeners();
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_threadReadKey, jsonEncode(_threadReadAt));
      } catch (_) {}
    }());
  }

  void _stopRemoteSync() {
    final client = Supabase.instance.client;
    for (final channel in [
      _presenceChannel,
      _storiesChannel,
      _storyViewsChannel,
      _storyLikesChannel,
      _messagesChannel,
      _placesChannel,
      _placeConfirmationsChannel,
      _placeRatingsChannel,
      _photoSuggestionsChannel,
      _profileReportsChannel,
      _storyReportsChannel,
      _postsChannel,
      _blocksChannel,
      _groupMessagesChannel,
      _groupsChannel,
      _chatChannel,
      _chatReactionsChannel,
      _friendshipsChannel,
      _profilesChannel,
      _callsChannel,
      _groupCallsChannel,
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
    _storyReportsChannel = null;
    _postsChannel = null;
    _blocksChannel = null;
    _postsRefreshTimer?.cancel();
    _postsRefreshTimer = null;
    _groupMessagesChannel = null;
    _groupsChannel = null;
    _chatChannel = null;
    _chatReactionsChannel = null;
    _friendshipsChannel = null;
    _profilesChannel = null;
    _callsChannel = null;
    _groupCallsChannel = null;
    _presenceChannel = null;
    onlineIds = {};
    _activeGroupCalls = {};
    callLog = [];
    groupCallLog = [];
    incomingCall = null;
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
    openStoryReports = [];
    _visitNights = {};
    posts = [];
    postsLoaded = false;
    _postComments.clear();
    _commentPreviews.clear();
    _blockedByMe = {};
    _blockedMe = {};
    _awardRanks = {};
    crashReports = [];
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
    _chatReplayPool = [];
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
    if (isGuest) {
      // A guest's server row never touches this phone's own profile.
      guestHandle = row['handle'] as String? ?? guestHandle;
      selfBanned = row['banned'] as bool? ?? false;
      notifyListeners();
      return;
    }
    selfBanned = row['banned'] as bool? ?? false;
    final wasRemoteAdmin = _remoteAdmin;
    _remoteAdmin = row['is_admin'] as bool? ?? false;
    if (_remoteAdmin != wasRemoteAdmin) _applyRadiusCap();
    if (_remoteAdmin && !wasRemoteAdmin) {
      // Just learned this account is an admin — pull in what's waiting.
      unawaited(_fetchProfileReports());
      unawaited(_fetchStoryReports());
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
    if (next.photoPath != null && !File(next.photoPath!).existsSync()) {
      // The local file is gone — rely on the uploaded copy.
      next = next.copyWith(clearPhotoPath: true);
    }
    if (_avatarUploading) {
      // Mid-upload — this row is from before it finished; leave the picture alone.
    } else if (next.photoPath != null && _avatarPending && !_avatarBackfillTried) {
      // Your last picture never finished uploading (offline, or the server
      // wasn't ready) — the server still has an older one. Try again now
      // rather than letting the old one come back.
      _avatarBackfillTried = true;
      unawaited(_uploadAvatar(next.photoPath!));
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      next = next.copyWith(photoUrl: avatarUrl);
    } else if (next.photoPath != null && !_avatarBackfillTried) {
      // A picture picked before it could be shared (older build, or the
      // server wasn't set up yet): upload it now so other people see it.
      _avatarBackfillTried = true;
      unawaited(_uploadAvatar(next.photoPath!));
    }
    final style = row['style'];
    final hasLocalStyle =
        next.nameBold || next.nameItalic || next.nameUnderline || next.nameCheckbox || next.nameColor != null || next.nameEffect != null;
    if (!hasLocalStyle && style is Map && style.isNotEmpty) {
      next = next.copyWith(
        nameBold: style['bold'] == true,
        nameItalic: style['italic'] == true,
        nameUnderline: style['underline'] == true,
        nameCheckbox: style['check'] == true,
        nameColor: (style['color'] as num?)?.toInt(),
        nameEffect: style['effect'] as String?,
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
        'effect': me.nameEffect,
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
      await _fetchPrivateDetails();
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
        final r = raw;
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
  static const photoSuggestedMessage = "Thanks! Your picture is waiting for approval — you'll get 1,000 points if it's approved.";
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
    } catch (e) {
      return _featureError(e, feature: 'Place pictures', phase: 'phase 10', fallback: "Couldn't add that picture");
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
      if (!_remotePersonIds.contains(id) || isHidden(id)) continue;
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

  /// A readable reason for a failed call to a newer database function: says
  /// so when the SQL update for that feature simply hasn't been run yet,
  /// shows the server's own message for other database errors, and only
  /// blames the connection when it really looks like one.
  String _featureError(Object e, {required String feature, required String phase, required String fallback}) {
    if (e is PostgrestException) {
      final m = e.message;
      final missing = e.code == 'PGRST202' ||
          e.code == '42883' ||
          e.code == '42P01' ||
          m.contains('Could not find the function') ||
          m.contains('does not exist') ||
          m.contains('schema cache');
      if (missing) return '$feature isn\'t switched on yet — the $phase database update hasn\'t been run.';
      if (m.isNotEmpty) return '$fallback ($m)';
    }
    return fallback;
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
      final joinsByGroup = <String, List<GroupJoin>>{};
      final others = <String>{};
      for (final raw in memberRows) {
        final r = raw;
        final gid = r['group_id'] as String?;
        final u = r['user_id'] as String?;
        if (gid == null || u == null) continue;
        (membersByGroup[gid] ??= []).add(u == uid ? 'me' : u);
        if (u != uid) others.add(u);
        final addedBy = r['added_by'] as String?;
        if (addedBy != null && addedBy != uid) others.add(addedBy);
        (joinsByGroup[gid] ??= []).add(GroupJoin(
          userId: u == uid ? 'me' : u,
          addedBy: addedBy == null ? null : (addedBy == uid ? 'me' : addedBy),
          at: DateTime.tryParse((r['joined_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ));
      }
      for (final list in joinsByGroup.values) {
        list.sort((a, b) => a.at.compareTo(b.at));
      }
      final next = <GroupChat>[];
      for (final raw in chatRows) {
        final r = raw;
        final id = r['id'] as String?;
        if (id == null) continue;
        final by = r['created_by'] as String?;
        if (by != null && by != uid) others.add(by);
        next.add(GroupChat(
          id: id,
          name: (r['name'] as String?) ?? 'Group',
          memberIds: membersByGroup[id] ?? const ['me'],
          createdBy: by == uid ? 'me' : (by ?? ''),
          createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
          photoUrl: (r['photo_url'] as String?)?.isNotEmpty == true ? r['photo_url'] as String : null,
          joins: joinsByGroup[id] ?? const [],
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
      gifUrl: row['gif_url'] as String?,
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
        final row = raw;
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
  Future<String?> sendGroupMessage(String groupId, String text, {String? mediaPath, String? mediaType, bool skipCooldown = false, String? gifUrl}) async {
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
    if (capped.trim().isEmpty && !hasMedia && gifUrl == null) return null;
    if (hasMedia) {
      if (!skipCooldown && _tooSoon('dmMedia', 5000)) return 'Slow down — one snap every few seconds.';
      try {
        final bytes = await File(mp).length();
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
      gifUrl: gifUrl,
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
        if (local.gifUrl != null) 'gif_url': local.gifUrl,
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

  /// Sets (or, with a null [path], removes) the group's picture. The image
  /// goes to the public picture bucket under your own folder, and the group
  /// row points at it. Returns null on success, otherwise a message to show.
  Future<String?> setGroupPhoto(String groupId, String? path) async {
    final uid = supabaseUserId;
    if (uid == null) return 'Log in first.';
    try {
      String? url;
      if (path != null) {
        url = await _uploadPlaceCover(uid, path);
        if (url == null) return "Couldn't upload that picture — pick one under 8 MB and check your connection.";
      }
      await Supabase.instance.client.rpc('set_group_photo', params: {'p_group': groupId, 'p_url': url});
      // Show it straight away, then let the refresh confirm.
      groups = [
        for (final g in groups)
          if (g.id == groupId)
            GroupChat(id: g.id, name: g.name, memberIds: g.memberIds, createdBy: g.createdBy, createdAt: g.createdAt, photoUrl: url, joins: g.joins)
          else
            g,
      ];
      notifyListeners();
      unawaited(_fetchGroups());
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Group pictures', phase: 'phase 12', fallback: "Couldn't set that picture");
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
        final r = raw;
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
    } catch (e) {
      return _featureError(e, feature: 'Reporting', phase: 'phase 10', fallback: "Couldn't send that report");
    }
  }

  Future<void> resolveProfileReport(String id) async {
    if (!isAdmin) return;
    try {
      await Supabase.instance.client.rpc('resolve_profile_report', params: {'p_id': id});
    } catch (_) {}
    await _fetchProfileReports();
  }

  // --- Story reports (the flag on a Story) -------------------------------

  /// Reported Stories waiting on an admin, one entry per Story (all its
  /// reports grouped), oldest first. Only ever filled for admins.
  List<StoryReport> openStoryReports = [];

  static const storyReportReasons = [
    'Nudity or sexual content',
    'Harassment or bullying',
    'Violence or threats',
    'Hate speech',
    'Drugs or dangerous stuff',
    'Spam or scam',
    'Something else',
  ];

  Future<void> _fetchStoryReports() async {
    final uid = supabaseUserId;
    if (uid == null || !isAdmin) {
      if (openStoryReports.isNotEmpty) {
        openStoryReports = [];
        notifyListeners();
      }
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('story_reports')
          .select()
          .eq('status', 'open')
          .order('created_at');
      final byKey = <String, List<Map<String, dynamic>>>{};
      final order = <String>[];
      final ids = <String>{};
      for (final raw in rows) {
        final r = raw;
        final id = r['id'] as String?;
        if (id == null) continue;
        final key = (r['story_id'] as String?) ?? (r['post_id'] as String?) ?? id;
        if (!byKey.containsKey(key)) order.add(key);
        (byKey[key] ??= []).add(r);
        final poster = r['poster_id'] as String?;
        final reporter = r['reporter_id'] as String?;
        if (poster != null) ids.add(poster);
        if (reporter != null) ids.add(reporter);
      }
      String? asMe(String? id) => id == null ? null : (id == uid ? 'me' : id);
      final out = <StoryReport>[];
      for (final key in order) {
        final group = byKey[key]!;
        final first = group.first;
        final reasons = <String>[];
        for (final r in group) {
          final reason = (r['reason'] as String?) ?? '';
          if (reason.isNotEmpty && !reasons.contains(reason)) reasons.add(reason);
        }
        out.add(StoryReport(
          id: first['id'] as String,
          reportIds: [for (final r in group) r['id'] as String],
          storyId: first['story_id'] as String?,
          kind: (first['kind'] as String?) ?? 'story',
          postId: first['post_id'] as String?,
          posterId: asMe(first['poster_id'] as String?),
          reasons: reasons,
          reporterIds: [
            for (final r in group)
              if (r['reporter_id'] != null) asMe(r['reporter_id'] as String)!,
          ],
          storyText: first['story_text'] as String?,
          storyMediaPath: first['story_media_path'] as String?,
          storyIsVideo: first['story_is_video'] as bool? ?? false,
          storyAnon: first['story_anon'] as bool? ?? false,
          storyPlaceName: first['story_place_name'] as String?,
          storyCreatedAt: DateTime.tryParse((first['story_created_at'] as String?) ?? '')?.toLocal(),
          createdAt: DateTime.tryParse((first['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ));
      }
      ids.remove(uid);
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      openStoryReports = out;
      notifyListeners();
    } catch (_) {
      // Offline, or phase 26 not run yet.
    }
  }

  /// Flags a Story for the admins. Returns a message to show.
  Future<String> reportStory(Story story, String reason) async {
    if (!canUseServer) return 'Sign in to report a story.';
    if (story.uid == 'me') return "That's your own story.";
    if (!_looksLikeUuid(story.id)) return "Thanks — we'll take a look.";
    if (_tooSoon('storyReport', 2000)) return 'One sec…';
    try {
      final res = await Supabase.instance.client.rpc('report_story', params: {'p_story': story.id, 'p_reason': reason}) as String?;
      return res ?? 'Thanks for reporting. The FUNKY team will review it.';
    } catch (e) {
      return _featureError(e, feature: 'Reporting stories', phase: 'phase 26', fallback: "Couldn't send that report");
    }
  }

  /// Admin: close a reported Story's reports. [remove] also deletes the
  /// Story for everyone and tells the poster. Returns an error or null.
  Future<String?> resolveStoryReport(StoryReport report, {required bool remove}) async {
    if (!isAdmin) return 'Admins only.';
    try {
      final res = await Supabase.instance.client.rpc('resolve_story_report', params: {'p_id': report.id, 'p_remove': remove}) as String?;
      if (res != null) return res;
      if (remove && report.storyId != null) {
        stories = stories.where((s) => s.id != report.storyId).toList();
      }
      if (remove && report.postId != null) {
        posts = posts.where((p) => p.id != report.postId).toList();
      }
      openStoryReports = openStoryReports.where((r) => r.id != report.id).toList();
      notifyListeners();
      _persist();
    } catch (e) {
      return _featureError(e, feature: 'Story reports', phase: 'phase 26', fallback: "Couldn't update that report");
    }
    await _fetchStoryReports();
    return null;
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
    } catch (e) {
      return _featureError(e, feature: 'Ratings', phase: 'phase 9', fallback: "Couldn't save your rating");
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
    final isPrivate = row['is_private'] == true;
    final publicStart = DateTime.tryParse((row['starts_at'] as String?) ?? '')?.toLocal();
    final built = Place(
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
      photoUrl: _resolvePlacePhoto(id, row),
      startsAt: publicStart,
      eventType: row['event_type'] as String?,
      hostPlaceId: row['host_place_id'] as String?,
      isPrivate: isPrivate,
      timeHidden: isPrivate && publicStart != null,
    );
    final d = isPrivate ? _privateDetails[id] : null;
    return d == null ? built : _withPrivate(built, d);
  }

  // --- Private events (phase 36) -----------------------------------------

  final Map<String, PrivateEventDetails> _privateDetails = {};
  final Map<String, String> _myEventStatus = {};
  final Map<String, List<EventGuest>> _eventGuests = {};
  bool _privateEventsOk = true;

  /// The real address/spot/time filled into a private event's place.
  Place _withPrivate(Place p, PrivateEventDetails d) {
    final addr = d.address?.trim();
    return p.withDetails(
      address: addr == null || addr.isEmpty ? 'Address not given' : addr,
      lat: d.lat,
      lng: d.lng,
      startsAt: d.startsAt,
      timeHidden: false,
    );
  }

  void _applyPrivateToPlace(String placeId) {
    final d = _privateDetails[placeId];
    if (d == null) return;
    final i = places.indexWhere((p) => p.id == placeId);
    if (i == -1 || !places[i].isPrivate) return;
    places = [...places]..[i] = _withPrivate(places[i], d);
  }

  PrivateEventDetails? privateDetailsFor(String placeId) => _privateDetails[placeId];

  /// Can see a private event's address, time, guests and chat: its host,
  /// anyone who entered the code, or an admin. Always true for a public one.
  bool isEventInsider(Place p) =>
      !p.isPrivate || p.by == 'me' || isAdmin || _privateDetails.containsKey(p.id) || _myEventStatus.containsKey(p.id);

  /// Your RSVP to a private event: 'going', 'maybe', 'cant', 'unlocked'
  /// (entered the code, no answer yet), or null.
  String? myEventStatus(String placeId) => _myEventStatus[placeId];

  List<EventGuest> eventGuests(String placeId) => (_eventGuests[placeId] ?? const <EventGuest>[]).where((g) => !isHidden(g.uid)).toList();

  int eventGuestCount(String placeId, String status) => eventGuests(placeId).where((g) => g.status == status).length;

  PrivateEventDetails _detailsFromRow(Map<String, dynamic> r, {String? code}) => PrivateEventDetails(
        placeId: r['place_id'] as String,
        address: r['address'] as String?,
        lat: (r['lat'] as num?)?.toDouble(),
        lng: (r['lng'] as num?)?.toDouble(),
        startsAt: DateTime.tryParse((r['starts_at'] as String?) ?? '')?.toLocal(),
        passcode: (r['passcode'] as String?) ?? code,
      );

  /// The private events you're in (host or guest): their real details and
  /// your RSVP. Runs with every places refresh.
  Future<void> _fetchPrivateDetails() async {
    final uid = supabaseUserId;
    if (!_privateEventsOk || uid == null) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client.from('private_event_details').select().limit(500);
      final mine = await client.from('event_guests').select('place_id,status').eq('user_id', uid);
      _privateDetails
        ..clear()
        ..addAll({
          for (final r in rows)
            if (r['place_id'] is String) r['place_id'] as String: _detailsFromRow(r),
        });
      _myEventStatus
        ..clear()
        ..addAll({
          for (final r in mine)
            if (r['place_id'] is String) r['place_id'] as String: (r['status'] as String?) ?? 'unlocked',
        });
    } on PostgrestException catch (e) {
      if (e.code == '42P01' || e.message.contains('does not exist') || e.message.contains('schema cache')) _privateEventsOk = false;
    } catch (_) {}
  }

  /// Who's on a private event's guest list (only works for insiders).
  Future<void> fetchEventGuests(String placeId) async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.from('event_guests').select().eq('place_id', placeId).order('created_at');
      final list = <EventGuest>[];
      final ids = <String>{};
      for (final r in rows) {
        final uid = r['user_id'] as String?;
        if (uid == null) continue;
        final at = DateTime.tryParse((r['updated_at'] as String?) ?? (r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
        list.add(EventGuest(uid: _asMe(uid), status: (r['status'] as String?) ?? 'unlocked', t: at.millisecondsSinceEpoch));
        if (uid != supabaseUserId) ids.add(uid);
      }
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      _eventGuests[placeId] = list;
      final me = list.where((g) => g.uid == 'me').toList();
      if (me.isNotEmpty) _myEventStatus[placeId] = me.first.status;
      notifyListeners();
    } catch (_) {}
  }

  /// Enter the host's code. Returns an error to show, or null when you're in.
  Future<String?> unlockPrivateEvent(String placeId, String code) async {
    if (selfBanned) return _bannedMessage;
    if (!signedIn || supabaseUserId == null) return 'Make an account to unlock private events.';
    final clean = code.trim();
    if (clean.isEmpty) return 'Type the code first.';
    if (_tooSoon('unlock:$placeId', 1200)) return null;
    try {
      final res = await Supabase.instance.client.rpc('unlock_private_event', params: {'p_place': placeId, 'p_code': clean});
      if (res is! Map) return "Couldn't unlock that — try again.";
      final err = res['error'];
      if (err is String && err.isNotEmpty) return err;
      _privateDetails[placeId] = _detailsFromRow({...res.cast<String, dynamic>(), 'place_id': placeId}, code: clean);
      _myEventStatus.putIfAbsent(placeId, () => 'unlocked');
      _applyPrivateToPlace(placeId);
      notifyListeners();
      unawaited(fetchEventGuests(placeId));
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Private events', phase: 'phase 36', fallback: "Couldn't unlock that");
    }
  }

  /// RSVP to a private event: 'going', 'maybe' or 'cant'. Returns an error or null.
  Future<String?> setEventRsvp(String placeId, String status) async {
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Make an account to RSVP.';
    final prev = _myEventStatus[placeId];
    if (prev == status) return null;
    _myEventStatus[placeId] = status;
    final guests = _eventGuests[placeId];
    if (guests != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _eventGuests[placeId] = [
        ...guests.where((g) => g.uid != 'me'),
        EventGuest(uid: 'me', status: status, t: now),
      ];
    }
    notifyListeners();
    try {
      final t = Supabase.instance.client.from('event_guests');
      final rows = await t
          .update({'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('place_id', placeId)
          .eq('user_id', uid)
          .select('place_id');
      // The host has no row until they answer.
      if (rows.isEmpty) await t.insert({'place_id': placeId, 'user_id': uid, 'status': status});
      unawaited(fetchEventGuests(placeId));
      return null;
    } catch (e) {
      if (prev == null) {
        _myEventStatus.remove(placeId);
      } else {
        _myEventStatus[placeId] = prev;
      }
      unawaited(fetchEventGuests(placeId));
      notifyListeners();
      return _featureError(e, feature: 'RSVPs', phase: 'phase 36', fallback: "Couldn't save your RSVP");
    }
  }

  /// The host takes someone off the guest list (they'd need the code again).
  Future<String?> removeEventGuest(String placeId, String guestUid) async {
    final real = guestUid == 'me' ? supabaseUserId : guestUid;
    if (real == null) return null;
    try {
      await Supabase.instance.client.from('event_guests').delete().eq('place_id', placeId).eq('user_id', real);
      if (guestUid == 'me') _myEventStatus.remove(placeId);
      await fetchEventGuests(placeId);
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Guest lists', phase: 'phase 36', fallback: "Couldn't remove them");
    }
  }

  // --- Event chat (phase 36) ---------------------------------------------

  final Map<String, List<EventMessage>> _eventMessages = {};

  List<EventMessage> eventMessages(String placeId) =>
      (_eventMessages[placeId] ?? const <EventMessage>[]).where((m) => !isHidden(m.uid)).toList();

  bool eventMessagesLoaded(String placeId) => _eventMessages.containsKey(placeId);

  /// Loads the newest 300 messages. Returns an error to show, or null.
  Future<String?> fetchEventMessages(String placeId) async {
    if (supabaseUserId == null) return 'Open FUNKY with a connection to see the chat.';
    try {
      final rows = await Supabase.instance.client
          .from('event_messages')
          .select()
          .eq('place_id', placeId)
          .order('created_at', ascending: false)
          .limit(300);
      final list = <EventMessage>[];
      final ids = <String>{};
      for (final r in rows.reversed) {
        final id = r['id'] as String?;
        final uid = r['sender_id'] as String?;
        if (id == null || uid == null) continue;
        final at = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
        list.add(EventMessage(id: id, placeId: placeId, uid: _asMe(uid), text: (r['text'] as String?) ?? '', t: at.millisecondsSinceEpoch));
        if (uid != supabaseUserId) ids.add(uid);
      }
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      final before = _eventMessages[placeId];
      final changed = before == null || before.length != list.length || (list.isNotEmpty && before.last.id != list.last.id);
      _eventMessages[placeId] = list;
      if (changed) notifyListeners();
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Event chat', phase: 'phase 36', fallback: "Couldn't load the chat");
    }
  }

  /// Returns an error to show, or null.
  Future<String?> sendEventMessage(String placeId, String text) async {
    if (selfBanned) return _bannedMessage;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Make an account to chat here.';
    var clean = text.trim();
    if (clean.isEmpty) return null;
    if (clean.length > 500) clean = clean.substring(0, 500);
    if (_tooSoon('event_msg', 700)) return 'Slow down a sec.';
    try {
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(
          () => Supabase.instance.client.from('event_messages').insert({'place_id': placeId, 'sender_id': uid, 'text': clean}).select());
      final r = rows.first;
      final at = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
      final m = EventMessage(id: r['id'] as String, placeId: placeId, uid: 'me', text: clean, t: at.millisecondsSinceEpoch);
      _eventMessages[placeId] = [...(_eventMessages[placeId] ?? const <EventMessage>[]).where((x) => x.id != m.id), m];
      notifyListeners();
      return null;
    } catch (e) {
      if (e is PostgrestException) {
        final m = e.message.toLowerCase();
        if (m.contains('rate limit')) return 'Slow down a sec.';
        if (e.code == '42501' || m.contains('row-level security')) return 'Enter the code to join this chat.';
      }
      return _featureError(e, feature: 'Event chat', phase: 'phase 36', fallback: "Couldn't send that");
    }
  }

  Future<void> deleteEventMessage(EventMessage m) async {
    try {
      await Supabase.instance.client.from('event_messages').delete().eq('id', m.id);
    } catch (_) {
      return;
    }
    _eventMessages[m.placeId] = (_eventMessages[m.placeId] ?? const <EventMessage>[]).where((x) => x.id != m.id).toList();
    notifyListeners();
  }

  /// Who took each place's picture, when it needs a credit (Google photos).
  final Map<String, String> placePhotoCredits = {};

  /// A place's approved picture. Imported venues store a Google photo as
  /// "gplace:places/…/photos/…", which loads through the venue-photo function.
  String? _resolvePlacePhoto(String placeId, Map<String, dynamic> row) {
    final raw = row['photo_url'] as String?;
    final credit = row['photo_credit'] as String?;
    if (credit != null && credit.isNotEmpty) {
      placePhotoCredits[placeId] = credit;
    } else {
      placePhotoCredits.remove(placeId);
    }
    if (raw != null && raw.startsWith('gplace:')) return venuePhotoUrl(raw.substring(7));
    return raw;
  }

  /// Where an imported venue's Google photo loads from.
  String venuePhotoUrl(String ref, {int width = 800}) =>
      '${SupabaseConfig.url}/functions/v1/venue-photo?ref=${Uri.encodeQueryComponent(ref)}&w=$width';

  // --- Venue import (admin) -----------------------------------------------

  /// Bars and clubs pulled in from OpenStreetMap, for the admin to review.
  List<VenueCandidate> venueCandidates = [];
  bool venueCandidatesLoaded = false;

  Future<void> fetchVenueCandidates() async {
    if (!isAdmin) return;
    try {
      final rows = await Supabase.instance.client
          .from('venue_candidates')
          .select()
          .order('distance_miles', ascending: true)
          .limit(2000);
      venueCandidates = [
        for (final r in rows)
          if (VenueCandidate.fromRow(r) case final c?) c,
      ];
      venueCandidatesLoaded = true;
      notifyListeners();
    } catch (_) {
      venueCandidatesLoaded = true;
      notifyListeners();
    }
  }

  /// Runs the OpenStreetMap import: bars, pubs & clubs within 50 miles of
  /// where you are right now — or your dropped pin — (Egg Harbor if
  /// location is off).
  /// Returns a sentence saying how it went.
  Future<String> importVenues() async {
    if (!isAdmin) return 'Admins only.';
    // Imports around your dropped pin if you're viewing another area,
    // otherwise around where you really are.
    if (!isViewingElsewhere) await requestLocation();
    final here = location ?? const LatLng(39.3926, -74.6202); // Egg Harbor Twp
    // The phone asks OpenStreetMap itself, then hands the list to the
    // database (supabase/phase21.sql).
    final List<Map<String, dynamic>> rows;
    try {
      rows = await OsmVenueFetcher.fetch(lat: here.lat, lng: here.lng);
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
    if (rows.isEmpty) return 'OpenStreetMap has no bars or clubs listed within 50 miles of here.';
    try {
      var added = 0;
      for (var i = 0; i < rows.length; i += 300) {
        final chunk = rows.sublist(i, math.min(i + 300, rows.length));
        final n = await Supabase.instance.client.rpc('import_venue_candidates', params: {'p_rows': chunk});
        if (n is num) added += n.toInt();
      }
      await fetchVenueCandidates();
      return added == 0
          ? 'Nothing new — you already have every bar & club near here (${rows.length} checked).'
          : '$added new bars & clubs to review (out of ${rows.length} found).';
    } catch (e) {
      return _featureError(e, feature: 'Venue import', phase: 'phase 21', fallback: "Couldn't save the list");
    }
  }

  // Venues whose missing address we've already looked up this session.
  final Set<String> _addressLookups = {};
  Future<void> _addressQueue = Future<void>.value();

  /// OpenStreetMap often has a venue's exact pin but no street address —
  /// this looks the address up from the pin (one at a time, gently) and
  /// saves it, so it only ever happens once per venue.
  void ensureVenueAddress(VenueCandidate v) {
    if (!isAdmin || v.address.trim().isNotEmpty || !_addressLookups.add(v.id)) return;
    _addressQueue = _addressQueue.then((_) async {
      final found = await AddressSearch.reverse(v.lat, v.lng);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (found == null || found.isEmpty) return;
      final address = found.length > 120 ? found.substring(0, 120) : found;
      venueCandidates = [for (final c in venueCandidates) c.id == v.id ? c.withAddress(address) : c];
      notifyListeners();
      try {
        await Supabase.instance.client.rpc('set_venue_address', params: {'p_id': v.id, 'p_address': address});
      } catch (_) {
        // Phase 22 not run yet — it still shows for now.
      }
    });
  }

  /// Admin: moves an imported venue's pin (and the live place, if approved).
  Future<String?> moveVenue(String id, LatLng to) async {
    if (!isAdmin) return 'Admins only.';
    try {
      await Supabase.instance.client.rpc('set_venue_location', params: {'p_id': id, 'p_lat': to.lat, 'p_lng': to.lng});
      await fetchVenueCandidates();
      unawaited(_fetchRemotePlaces());
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Moving pins', phase: 'phase 20', fallback: "Couldn't move that pin");
    }
  }

  /// Admin: drags a place's pin to a new spot on the map.
  Future<String?> adminMovePlace(String placeId, LatLng to) async {
    if (!isAdmin) return 'Admins only.';
    final i = places.indexWhere((p) => p.id == placeId);
    if (i == -1) return 'That place is gone.';
    final old = places[i];
    // Show it moved right away; the server confirms below.
    places = [...places]..[i] = old.movedTo(to.lat, to.lng);
    notifyListeners();
    if (!_remotePlaceIds.contains(placeId)) {
      _persist();
      return null;
    }
    try {
      final rows = await Supabase.instance.client.from('places').update({'lat': to.lat, 'lng': to.lng}).eq('id', placeId).select('id');
      if (rows.isEmpty) throw Exception('not allowed');
      return null;
    } catch (_) {
      final j = places.indexWhere((p) => p.id == placeId);
      if (j != -1) {
        places = [...places]..[j] = old;
        notifyListeners();
      }
      return "Couldn't move that pin — check your connection.";
    }
  }

  /// How close you have to be to a place to post to its story.
  static const double placeStoryMaxMiles = 2;

  /// Before posting to a place's story: makes sure location is on and
  /// you're within [placeStoryMaxMiles] of it. Null means go ahead;
  /// otherwise it's the reason to show. Area posts ('main') always pass.
  Future<String?> placeStoryBlockReason(String place) async {
    if (place == 'main') return null;
    Place? target;
    for (final p in places) {
      if (p.id == place) target = p;
    }
    if (target == null) return null;
    await requestLocation();
    // Your real GPS spot, even if an admin has dropped their pin elsewhere.
    final here = _gpsLocation;
    if (locationStatus != LocationStatus.granted || here == null) {
      return "Turn on location for FUNKY to post to ${target.name}'s story — you have to actually be there.";
    }
    final miles = milesBetween(here, LatLng(target.lat, target.lng));
    if (miles > placeStoryMaxMiles) {
      return 'Too far — you need to be within ${placeStoryMaxMiles.round()} miles of ${target.name} to post to its story '
          "(you're ${miles.toStringAsFixed(1)} mi away). Post to Area instead.";
    }
    return null;
  }

  /// Uploads [path] as an imported venue's photo (and swaps it in on the
  /// map if the venue is already live). Null means it worked.
  Future<String?> setVenuePhoto(String id, String path) async {
    final uid = supabaseUserId;
    if (!isAdmin || uid == null) return 'Admins only.';
    final url = await _uploadPlaceCover(uid, path);
    if (url == null) return "Couldn't upload that photo — try a smaller one.";
    try {
      await Supabase.instance.client.rpc('set_venue_photo', params: {'p_id': id, 'p_url': url});
      await fetchVenueCandidates();
      unawaited(_fetchRemotePlaces());
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Venue photos', phase: 'phase 19', fallback: "Couldn't save that photo");
    }
  }

  /// Approve / deny / ask for changes on an imported venue, with optional
  /// edits (name, bar/club, which photo, a note). Null means it worked.
  Future<String?> reviewVenue(String id, String decision, {String? note, String? name, String? kind, int? photoIndex, String? address}) async {
    if (!isAdmin) return 'Admins only.';
    try {
      await Supabase.instance.client.rpc('review_venue', params: {
        'p_id': id,
        'p_decision': decision,
        'p_note': note,
        'p_name': name,
        'p_kind': kind,
        'p_photo_index': photoIndex,
        'p_address': address,
      });
      await fetchVenueCandidates();
      if (decision == 'approve') unawaited(_fetchRemotePlaces());
      return null;
    } catch (e) {
      return _featureError(e, feature: 'Venue import', phase: 'phase 19', fallback: "Couldn't save that");
    }
  }

  /// Replaces the backend-sourced places with a fresh copy. A place lasts 24
  /// hours from when it was added; only a place a FUNKY Admin verified stays
  /// past that. Crowd confirmations still mark a place verified for the
  /// night, but no longer keep it around.
  void _applyRemotePlaces(List<dynamic> rows, List<dynamic> confRows) {
    final uid = supabaseUserId;
    final confByPlace = <String, List<String>>{};
    for (final c in confRows) {
      final pid = c['place_id'] as String?;
      final u = c['user_id'] as String?;
      if (pid == null || u == null) continue;
      (confByPlace[pid] ??= []).add(u == uid ? 'me' : u);
    }
    final fetched = <Place>[];
    final verifiedByAdmin = <String>{};
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final place = _placeFromRow(row);
      if (place == null) continue;
      final adminVerified = row['admin_verified'] as bool? ?? false;
      final created = DateTime.tryParse((row['created_at'] as String?) ?? '');
      var expired = created != null && DateTime.now().difference(created.toLocal()) > const Duration(hours: 24);
      // A dated party/event (phase 33) stays until its night is over.
      final night = place.night;
      if (night != null) expired = night.compareTo(sessionKey()) < 0;
      if (!adminVerified && expired) continue;
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
      unawaited(_fetchPollComments(fetchedIds.toList()));
    } catch (_) {
      // Offline — keep what's showing.
    }
  }

  // --- Poll comments (phase 39) -------------------------------------------

  final Map<String, List<PostComment>> _pollComments = {};

  /// Every comment on a poll, oldest first. [PostComment.postId] holds the
  /// poll's id.
  List<PostComment> pollCommentsFor(String pollId) =>
      (_pollComments[pollId] ?? const <PostComment>[]).where((c) => !isHidden(c.uid)).toList();

  /// The newest two, for under the poll in the feed.
  List<PostComment> pollCommentPreview(String pollId) {
    final all = pollCommentsFor(pollId);
    return all.length <= 2 ? all : all.sublist(all.length - 2);
  }

  bool canCommentOnPoll(String pollId) => _remotePollIds.contains(pollId);

  PostComment _pollCommentFromRow(Map<String, dynamic> r) {
    final at = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    return PostComment(
      id: r['id'] as String,
      postId: r['poll_id'] as String,
      uid: _asMe(r['uid'] as String),
      text: (r['text'] as String?) ?? '',
      t: at.millisecondsSinceEpoch,
    );
  }

  Future<void> _fetchPollComments(List<String> pollIds) async {
    if (pollIds.isEmpty || supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('poll_comments')
          .select()
          .inFilter('poll_id', pollIds.take(100).toList())
          .order('created_at')
          .limit(1000);
      final byPoll = <String, List<PostComment>>{};
      final ids = <String>{};
      for (final r in rows) {
        if (r['id'] is! String || r['poll_id'] is! String || r['uid'] is! String) continue;
        final c = _pollCommentFromRow(r);
        (byPoll[c.postId] ??= []).add(c);
        if (r['uid'] != supabaseUserId) ids.add(r['uid'] as String);
      }
      if (ids.isNotEmpty) await _ensurePeopleFor(ids.toList());
      for (final id in pollIds) {
        _pollComments[id] = byPoll[id] ?? const <PostComment>[];
      }
      notifyListeners();
    } catch (_) {
      // Phase 39 not run yet — polls just show without comments.
    }
  }

  /// Reloads one poll's comments (its comments page polls this).
  Future<void> refreshPollComments(String pollId) => _fetchPollComments([pollId]);

  /// Returns an error to show, or null.
  Future<String?> addPollComment(String pollId, String text) async {
    if (selfBanned) return _bannedMessage;
    final uid = supabaseUserId;
    if (!signedIn || uid == null) return 'Log in to comment.';
    if (!_remotePollIds.contains(pollId)) return "This poll isn't on the server yet.";
    var clean = text.trim();
    if (clean.isEmpty) return null;
    if (clean.length > 300) clean = clean.substring(0, 300);
    if (_tooSoon('poll_comment', 1500)) return 'Slow down a sec.';
    try {
      final rows = await _withProfileRepair<List<Map<String, dynamic>>>(
          () => Supabase.instance.client.from('poll_comments').insert({'poll_id': pollId, 'uid': uid, 'text': clean}).select());
      final c = _pollCommentFromRow(rows.first);
      _pollComments[pollId] = [...(_pollComments[pollId] ?? const <PostComment>[]).where((x) => x.id != c.id), c];
      notifyListeners();
      return null;
    } catch (e) {
      if (e is PostgrestException && e.message.toLowerCase().contains('rate limit')) return 'Slow down a sec.';
      return _featureError(e, feature: 'Poll comments', phase: 'phase 39', fallback: "Couldn't send that comment");
    }
  }

  Future<void> deletePollComment(PostComment c) async {
    try {
      await Supabase.instance.client.from('poll_comments').delete().eq('id', c.id);
    } catch (_) {
      return;
    }
    _pollComments[c.postId] = (_pollComments[c.postId] ?? const <PostComment>[]).where((x) => x.id != c.id).toList();
    notifyListeners();
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
      replyToId: row['reply_to'] as String?,
      replyText: row['reply_text'] as String?,
      replyHandle: row['reply_handle'] as String?,
      sharedPlaceId: row['place_id'] as String?,
      pollId: row['poll_id'] as String?,
      gifUrl: row['gif_url'] as String?,
      reachMiles: (row['reach_miles'] as num?)?.toInt(),
    );
  }

  /// Whether a Live Chat message from [lat],[lng] shows for you: it's inside
  /// your radius, or you're inside the sender's reach (their radius when
  /// they sent it). So two friends with different radiuses still see each
  /// other whenever either one's circle covers the other.
  bool _chatInRange(LatLng here, double lat, double lng, int? reach) {
    final d = milesBetween(here, LatLng(lat, lng));
    if (d <= rangeMiles) return true;
    return reach != null && d <= reach;
  }

  // The last 24 hours of Live Chat (the server never gives out older) —
  // only used by Home's chat preview to keep looping old messages right
  // after the 2 PM reset, when tonight's chat is still empty. The real Live
  // Chat still only shows tonight's.
  List<ChatMessage> _chatReplayPool = [];

  /// Tonight's area chat plus anything from the last 24 hours, oldest first.
  List<ChatMessage> get liveChatReplay {
    final here = location ?? defaultLocation;
    final byId = <String, ChatMessage>{};
    for (final m in _chatReplayPool) {
      byId[m.id] = m;
    }
    for (final m in liveChatMessages) {
      byId[m.id] = m;
    }
    final list = byId.values.where((m) {
      if (m.uid != 'me' && isHidden(m.uid)) return false;
      final lat = m.lat;
      final lng = m.lng;
      if (lat == null || lng == null) return m.uid == 'me';
      return m.uid == 'me' || _chatInRange(here, lat, lng, m.reachMiles);
    }).toList();
    list.sort((a, b) => a.t.compareTo(b.t));
    return list;
  }

  Future<void> _fetchRemoteChat() async {
    if (supabaseUserId == null) return;
    try {
      final dayAgo = DateTime.now().subtract(const Duration(hours: 24)).toUtc().toIso8601String();
      final sessionStart = _sessionStartMs();
      final rows = await Supabase.instance.client
          .from('chat_messages')
          .select()
          .gte('created_at', dayAgo)
          .order('created_at', ascending: false)
          .limit(400);
      final fetched = <ChatMessage>[];
      final pool = <ChatMessage>[];
      for (final row in rows) {
        final msg = _chatFromRow(row);
        if (msg == null) continue;
        pool.add(msg);
        if (msg.t < sessionStart) continue; // before the 2 PM reset
        fetched.add(msg);
        _remoteChatIds.add(msg.id);
      }
      await _ensurePeopleFor(pool.map((m) => m.uid).where((u) => u != 'anon' && u != 'me'));
      _chatReplayPool = pool;
      notifyListeners();
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
    _chatReplayPool = _chatReplayPool.where((m) => m.id != id).toList();
    final before = messages.length;
    messages = messages.where((m) => m.id != id).toList();
    if (messages.length != before) notifyListeners();
  }

  /// The Live Chat feed for display: tonight's area messages from people
  /// within your radius of where you are (a message with no recorded
  /// location only shows to whoever sent it), minus anyone who's banned.
  List<ChatMessage> get liveChatMessages {
    final here = location ?? defaultLocation;
    final start = _sessionStartMs();
    final list = messages.where((m) {
      if (m.room != 'main') return false;
      if (m.t < start) return false;
      if (m.uid != 'me' && isHidden(m.uid)) return false;
      final lat = m.lat;
      final lng = m.lng;
      // No location on it: only the sender sees it (it could be from anywhere).
      if (lat == null || lng == null) return m.uid == 'me';
      return m.uid == 'me' || _chatInRange(here, lat, lng, m.reachMiles);
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
  /// Public hook so screens (e.g. the Story viewers list) can make sure the
  /// profiles for some ids are loaded.
  Future<void> loadPeople(Iterable<String> uids) => _ensurePeopleFor(uids);

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
      nameEffect: styleMap['effect'] as String?,
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
      lat: (row['lat'] as num?)?.toDouble(),
      lng: (row['lng'] as num?)?.toDouble(),
      mediaPath: mediaPath,
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
      // Newest first so the server's 1,000-row cap can never cut off
      // tonight's Stories, then back to oldest-first.
      final rows = (await client.from('stories').select().order('created_at', ascending: false).limit(1000)).reversed.toList();
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
      storyId: row['story_id'] as String?,
      storyText: row['story_text'] as String?,
      storyMediaPath: row['story_media_path'] as String?,
      storyIsVideo: row['story_is_video'] as bool? ?? false,
      gifUrl: row['gif_url'] as String?,
    );
  }

  // ── Story replies in DMs ────────────────────────────────────────────────
  // The Story a just-sent reply answered, kept for this run so your own
  // bubble can show the picture straight away (from the Story's already-
  // signed URL or local file) before anything round-trips the server.
  final Map<String, Story> _storyReplySnapshots = {};
  final Map<String, Future<String?>> _storyPreviewUrls = {};
  final Map<String, String> _storyPreviewResolved = {};

  /// The Story [m] replied to, if it's still around on this phone (yours or
  /// one you've loaded) — null once it's expired or was never fetched here.
  Story? storyForReply(ChatMessage m) {
    final snap = _storyReplySnapshots[m.id];
    if (snap != null) return snap;
    final id = m.storyId;
    if (id == null) return null;
    for (final s in stories) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// A signed URL for a replied-to Story's picture (stories bucket is
  /// private). The same Future is handed back for the same path, so a
  /// FutureBuilder in a thread doesn't restart (and flash) on every rebuild.
  /// Resolves to null when it's gone or this account can't read it; a miss
  /// is retried after a couple of minutes, a hit is re-signed after 5 hours.
  Future<String?> storyPreviewUrl(String path) {
    final cached = _storyPreviewUrls[path];
    if (cached != null) return cached;
    final f = () async {
      if (!canUseServer) return null;
      try {
        final url = await Supabase.instance.client.storage.from('stories').createSignedUrl(path, 6 * 3600);
        _storyPreviewResolved[path] = url;
        return url;
      } catch (_) {
        return null;
      }
    }();
    _storyPreviewUrls[path] = f;
    unawaited(f.then((url) {
      Timer(url == null ? const Duration(minutes: 2) : const Duration(hours: 5), () {
        if (identical(_storyPreviewUrls[path], f)) {
          _storyPreviewUrls.remove(path);
          _storyPreviewResolved.remove(path);
        }
      });
    }));
    return f;
  }

  /// The already-signed preview URL for [path], if we have one — lets a
  /// freshly built bubble show the picture on its very first frame.
  String? cachedStoryPreviewUrl(String path) => _storyPreviewResolved[path];

  String? _storyReplyCaption(Story s) {
    final t = s.text?.trim();
    if (t != null && t.isNotEmpty) return t.length > 120 ? '${t.substring(0, 120)}…' : t;
    final p = s.placeName?.trim();
    if (p != null && p.isNotEmpty) return '📍 $p';
    return null;
  }

  static final RegExp _uuidRe = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  bool _looksLikeUuid(String s) => _uuidRe.hasMatch(s);

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
      if (!_isRealPersonId(p.id) || p.handle.isEmpty || isHidden(p.id)) return false;
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
    if (!signedIn && !isGuest) {
      await _startGuestSession();
      return;
    }
    if (supabaseUserId == null) return;
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
      _fetchPlaceRsvps(),
      _pingPresence(),
      _fetchPlaceRatings(),
      _fetchPhotoSuggestions(),
      _fetchProfileReports(),
      _fetchStoryReports(),
      _fetchPlaceVisits(),
      _fetchPlaceInvites(),
      _fetchBlocks(),
      _fetchPosts(),
      _awardAndLoadTopPosts(),
      _fetchGroups(),
      refreshGroupCalls(),
      fetchCallLog(),
      fetchGroupCallLog(),
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
      // A new invite: show it on the place (and let you into a private one).
      if (n.kind == 'invite') {
        unawaited(_fetchPlaceInvites());
        final placeId = n.data['place_id'];
        if (placeId is String) unawaited(refreshPrivateEvent(placeId));
      }
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

  /// Removes some notifications (a swipe on the Notifications screen).
  Future<void> deleteNotifications(List<String> ids) async {
    if (ids.isEmpty) return;
    final gone = ids.toSet();
    notifications = notifications.where((n) => !gone.contains(n.id)).toList();
    _syncBadge();
    notifyListeners();
    try {
      await Supabase.instance.client.from('notifications').delete().inFilter('id', ids);
    } catch (_) {}
  }

  /// Makes sure [id]'s profile is loaded so a screen opened from a
  /// notification (a DM thread, a profile) has someone to show.
  Future<void> ensurePerson(String id) => _ensurePeopleFor([id]);

  /// Loads the profiles of everyone in your notifications (for their
  /// pictures on the Notifications screen).
  Future<void> ensureNotificationPeople() {
    final ids = <String>{
      for (final n in notifications)
        if (n.data['from'] is String && n.data['from'] != supabaseUserId) n.data['from'] as String,
    };
    return ids.isEmpty ? Future.value() : _ensurePeopleFor(ids.toList());
  }

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

  static const _radiusKey = 'funky.radiusMiles';

  // The radius you picked (saved on this phone). What's actually used is
  // this, capped at 50 miles unless you're an admin (up to 5,000).
  int? _savedRadiusMiles;

  int get radiusCapMiles => isAdmin ? adminMaxRangeMiles : maxRangeMiles;

  void _applyRadiusCap() {
    final next = (_savedRadiusMiles ?? defaultRangeMiles.round()).clamp(minRangeMiles, radiusCapMiles).toDouble();
    if (next == rangeMiles) return;
    rangeMiles = next;
    notifyListeners();
  }

  /// Your own "near me" distance: 1–50 miles (10 by default), or up to 5,000
  /// for admins. Saved on this phone, and sent up with your location so the
  /// server's "new place near you" alerts use the same distance.
  Future<void> setRadiusMiles(int miles) async {
    final next = miles.clamp(minRangeMiles, radiusCapMiles).toDouble();
    _savedRadiusMiles = next.round();
    if (next == rangeMiles) return;
    rangeMiles = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_radiusKey, next.round());
    } catch (_) {}
    // Force the location row to be re-sent with the new radius.
    _syncedLocationAt = null;
    _syncedLocation = null;
    _syncLocationUp();
  }

  // --- Video calls ------------------------------------------------------

  /// A call that's ringing for you right now, if any. The app root shows the
  /// answer/decline screen whenever this appears.
  IncomingCall? incomingCall;
  String? lastCallError;

  // --- Call history (shown as lines inside the DM / group chat) ---------

  List<CallLogEntry> callLog = [];
  List<GroupCallLogEntry> groupCallLog = [];

  List<CallLogEntry> callLogWith(String personId) => callLog.where((c) => c.peerId == personId).toList();
  List<GroupCallLogEntry> groupCallLogFor(String groupId) => groupCallLog.where((c) => c.groupId == groupId).toList();

  Future<void> fetchCallLog() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await Supabase.instance.client.from('calls').select().order('created_at', ascending: false).limit(200);
      final next = <CallLogEntry>[];
      for (final raw in rows) {
        final e = CallLogEntry.fromRow(raw, uid);
        if (e != null) next.add(e);
      }
      callLog = next;
      notifyListeners();
    } catch (_) {
      // Offline, or phase 13 not run yet — no call lines.
    }
  }

  Timer? _groupCallRefreshTimer;

  // Everyone on a call pings the table every ~25 s — batch the refreshes.
  void _scheduleGroupCallRefresh() {
    _groupCallRefreshTimer?.cancel();
    _groupCallRefreshTimer = Timer(const Duration(seconds: 2), () {
      unawaited(refreshGroupCalls());
      unawaited(fetchGroupCallLog());
    });
  }

  Future<void> fetchGroupCallLog() async {
    final uid = supabaseUserId;
    if (uid == null) return;
    try {
      final rows = await Supabase.instance.client.from('group_calls').select().order('created_at', ascending: false).limit(200);
      final next = <GroupCallLogEntry>[];
      final starters = <String>{};
      for (final raw in rows) {
        final e = GroupCallLogEntry.fromRow(raw, uid);
        if (e == null) continue;
        next.add(e);
        if (e.startedBy != 'me') starters.add(e.startedBy);
      }
      if (starters.isNotEmpty) await _ensurePeopleFor(starters);
      groupCallLog = next;
      notifyListeners();
    } catch (_) {}
  }

  void _onCallRow(Map<String, dynamic> row) {
    final uid = supabaseUserId;
    if (uid == null) return;
    final id = row['id'] as String?;
    if (id == null) return;
    unawaited(fetchCallLog());
    final status = row['status'] as String?;
    if (row['callee_id'] == uid && status == 'ringing') {
      final created = DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
      // Stale rings (the app was closed when it came in) aren't worth showing.
      if (DateTime.now().difference(created) > const Duration(seconds: 50)) return;
      final from = row['caller_id'] as String?;
      if (from == null) return;
      unawaited(() async {
        await _ensurePeopleFor([from]);
        if (incomingCall?.id == id) return;
        incomingCall = IncomingCall(id: id, fromId: from, at: created);
        notifyListeners();
      }());
    } else if (incomingCall?.id == id && status != 'ringing') {
      // The caller hung up (or someone answered elsewhere).
      incomingCall = null;
      notifyListeners();
    }
  }

  // --- Group video calls --------------------------------------------------

  // groupId -> the call id that's live in it right now.
  Map<String, String> _activeGroupCalls = {};

  /// The video call going on in this group right now, if any.
  String? activeGroupCallId(String groupId) => _activeGroupCalls[groupId];

  Future<void> refreshGroupCalls() async {
    if (supabaseUserId == null) return;
    try {
      final rows = await Supabase.instance.client.rpc('active_group_calls');
      final next = <String, String>{};
      if (rows is List) {
        for (final raw in rows) {
          if (raw is! Map) continue;
          final gid = raw['group_id'] as String?;
          final id = raw['id'] as String?;
          if (gid != null && id != null) next[gid] = id;
        }
      }
      var changed = next.length != _activeGroupCalls.length;
      if (!changed) {
        for (final e in next.entries) {
          if (_activeGroupCalls[e.key] != e.value) changed = true;
        }
      }
      _activeGroupCalls = next;
      if (changed) notifyListeners();
    } catch (_) {
      // Offline, or phase 14 not run yet — no banner.
    }
  }

  /// Starts a video call in the group, or joins the one already going.
  /// Returns the call id, or null with [lastCallError] set.
  Future<String?> startGroupCall(String groupId) async {
    lastCallError = null;
    if (!signedIn || supabaseUserId == null) {
      lastCallError = 'Log in to make a video call.';
      return null;
    }
    try {
      final res = await Supabase.instance.client.rpc('start_group_call', params: {'p_group': groupId});
      final id = res as String?;
      if (id == null) {
        lastCallError = "Couldn't start that call.";
        return null;
      }
      _activeGroupCalls = {..._activeGroupCalls, groupId: id};
      notifyListeners();
      return id;
    } catch (e) {
      lastCallError = _featureError(e, feature: 'Group video calls', phase: 'phase 14', fallback: "Couldn't start that call");
      if (e is PostgrestException && e.message.isNotEmpty && !lastCallError!.contains("isn't switched on")) {
        lastCallError = e.message;
      }
      return null;
    }
  }

  Future<void> pingGroupCall(String callId) async {
    try {
      await Supabase.instance.client.rpc('ping_group_call', params: {'p_call': callId});
    } catch (_) {}
  }

  Future<void> endGroupCall(String callId) async {
    try {
      await Supabase.instance.client.rpc('end_group_call', params: {'p_call': callId});
      _activeGroupCalls = {
        for (final e in _activeGroupCalls.entries)
          if (e.value != callId) e.key: e.value,
      };
      notifyListeners();
    } catch (_) {}
  }

  void clearIncomingCall() {
    if (incomingCall == null) return;
    incomingCall = null;
    notifyListeners();
  }

  /// Rings a friend. Returns the call id, or null with [lastCallError] set.
  Future<String?> startCall(String personId) async {
    lastCallError = null;
    if (!signedIn || supabaseUserId == null) {
      lastCallError = 'Log in to make a video call.';
      return null;
    }
    if (!isFriendsWith(personId)) {
      lastCallError = 'You can only video chat with friends.';
      return null;
    }
    try {
      final res = await Supabase.instance.client.rpc('start_call', params: {'p_callee': personId});
      final id = res as String?;
      if (id == null) lastCallError = "Couldn't start that call.";
      return id;
    } catch (e) {
      lastCallError = _featureError(e, feature: 'Video calls', phase: 'phase 13', fallback: "Couldn't start that call");
      if (e is PostgrestException && e.message.isNotEmpty && !lastCallError!.contains("isn't switched on")) {
        lastCallError = e.message;
      }
      return null;
    }
  }

  /// accept | decline | cancel | end. Returns null on success, otherwise a message.
  Future<String?> respondToCall(String callId, String action) async {
    try {
      await Supabase.instance.client.rpc('respond_call', params: {'p_call': callId, 'p_action': action});
      return null;
    } catch (e) {
      return _rpcMessage(e);
    }
  }

  Future<CallInfo?> fetchCall(String callId) async {
    final uid = supabaseUserId;
    if (uid == null) return null;
    try {
      final row = await Supabase.instance.client.from('calls').select().eq('id', callId).maybeSingle();
      if (row == null) return null;
      final caller = row['caller_id'] as String?;
      final callee = row['callee_id'] as String?;
      if (caller == null || callee == null) return null;
      return CallInfo(
        id: callId,
        callerId: caller == uid ? 'me' : caller,
        calleeId: callee == uid ? 'me' : callee,
        status: (row['status'] as String?) ?? 'ended',
        createdAt: DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Asks the call-token function for the LiveKit key to this call's room.
  /// On failure returns null with [lastCallError] set.
  Future<CallCredentials?> fetchCallCredentials(String callId, {bool group = false}) async {
    lastCallError = null;
    try {
      final res = await Supabase.instance.client.functions
          .invoke('call-token', body: group ? {'group_call_id': callId} : {'call_id': callId});
      final data = res.data;
      if (data is Map && data['url'] is String && data['token'] is String) {
        return CallCredentials(url: data['url'] as String, token: data['token'] as String);
      }
      lastCallError = (data is Map && data['error'] is String) ? data['error'] as String : "Couldn't connect the call.";
      return null;
    } on FunctionException catch (e) {
      final d = e.details;
      if (e.status == 404) {
        lastCallError = "Video calling isn't switched on yet — the call-token function hasn't been deployed.";
      } else if (d is Map && d['error'] is String) {
        lastCallError = d['error'] as String;
      } else {
        lastCallError = "Couldn't connect the call — check your connection and try again.";
      }
      return null;
    } catch (_) {
      lastCallError = "Couldn't connect the call — check your connection and try again.";
      return null;
    }
  }

  /// Tells the server roughly where you last opened the app — only used to
  /// work out whether a newly verified place is within your area, and
  /// only visible to you. Throttled: at most every 30 min unless you moved
  /// more than a mile.
  void _syncLocationUp() {
    final uid = supabaseUserId;
    // Always your real spot — a dropped admin pin never goes to the server.
    final loc = _gpsLocation;
    if (uid == null || loc == null || !notifPrefs.place) return;
    final prev = _syncedLocation;
    final at = _syncedLocationAt;
    if (prev != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 30) && milesBetween(prev, loc) < 1) return;
    _syncedLocation = loc;
    _syncedLocationAt = DateTime.now();
    unawaited(() async {
      final row = <String, dynamic>{
        'user_id': uid,
        'lat': loc.lat,
        'lng': loc.lng,
        'radius_miles': rangeMiles.round(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      try {
        try {
          await Supabase.instance.client.from('user_locations').upsert(row);
        } catch (_) {
          // The radius column only exists once phase 12 has been run — fall
          // back to the plain location so alerts keep working meanwhile.
          row.remove('radius_miles');
          await Supabase.instance.client.from('user_locations').upsert(row);
        }
      } catch (_) {
        _syncedLocationAt = null;
      }
    }());
  }

  // --- Saved posts (kept on this phone) -------------------------------------

  static const _savedPostsKey = 'funky.savedPosts';
  Set<String> savedPostIds = {};
  bool _savedPostsLoaded = false;

  bool isPostSaved(String id) {
    if (!_savedPostsLoaded) unawaited(_loadSavedPosts());
    return savedPostIds.contains(id);
  }

  Future<void> _loadSavedPosts() async {
    if (_savedPostsLoaded) return;
    _savedPostsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_savedPostsKey);
      if (list != null && list.isNotEmpty) {
        savedPostIds = list.toSet();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Bookmark a post (or take the bookmark off). Saved on this phone.
  Future<void> toggleSavePost(String id) async {
    await _loadSavedPosts();
    savedPostIds = savedPostIds.contains(id) ? ({...savedPostIds}..remove(id)) : {...savedPostIds, id};
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_savedPostsKey, savedPostIds.toList());
    } catch (_) {}
  }

  /// Posts you bookmarked that are still around, newest first.
  List<Post> get savedPosts {
    if (!_savedPostsLoaded) unawaited(_loadSavedPosts());
    final list = posts.where((p) => savedPostIds.contains(p.id)).toList();
    list.sort((a, b) => b.t.compareTo(a.t));
    return list;
  }

  // --- Live Chat: who's online, replies, GIFs (phase 33) -------------------

  /// How many people have the app open within your radius (you included),
  /// or null until the server has answered.
  int? onlineNearby;

  Future<void> _pingPresence() async {
    final loc = location;
    if (loc == null || supabaseUserId == null) return;
    try {
      final n = await Supabase.instance.client.rpc('ping_presence', params: {
        'p_lat': loc.lat,
        'p_lng': loc.lng,
        'p_radius_miles': rangeMiles,
      });
      final v = (n as num?)?.toInt();
      if (v != onlineNearby) {
        onlineNearby = v;
        notifyListeners();
      }
    } catch (_) {
      // Phase 33 not run yet, or offline — the count just doesn't show.
    }
  }

  /// Checks the online count again right away (Live Chat just opened).
  void refreshOnlineNearby() => unawaited(_pingPresence());

  /// The name a Live Chat message shows ('anonymous' for ghost mode).
  String chatHandleFor(ChatMessage m) {
    if (m.anon) return 'anonymous';
    if (m.uid == 'me') return myChatHandle;
    return people[m.uid]?.handle ?? 'someone';
  }

  /// The message a reply points at, if it's still around.
  ChatMessage? chatMessageById(String? id) {
    if (id == null) return null;
    for (final m in messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The GIPHY key for GIF search, set by an admin (app_config table).
  String? giphyKey;

  Future<void> _fetchAppConfig() async {
    try {
      final rows = await Supabase.instance.client.from('app_config').select('key,value');
      String? key;
      for (final r in rows) {
        if (r['key'] == 'giphy_key') key = r['value'] as String?;
      }
      final next = (key == null || key.trim().isEmpty) ? null : key.trim();
      if (next != giphyKey) {
        giphyKey = next;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Admins: turn GIF search on with a GIPHY API key (empty turns it off).
  Future<String?> setGiphyKey(String key) async {
    if (!isAdmin) return 'Admins only.';
    final clean = key.trim();
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': 'giphy_key',
        'value': clean.isEmpty ? null : clean,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      giphyKey = clean.isEmpty ? null : clean;
      notifyListeners();
      return null;
    } catch (e) {
      return _featureError(e, feature: 'GIFs', phase: 'phase 33', fallback: "Couldn't save the key");
    }
  }

  // --- FUNKY avatars (phase 33) ---------------------------------------------

  /// Use one of FUNKY's own avatars ("preset:raccoon") as your picture.
  Future<String?> setAvatarPreset(String value) async {
    if (!signedIn) return 'Make an account to pick a picture.';
    me = me.copyWith(clearPhotoPath: true, photoUrl: value);
    notifyListeners();
    _persist();
    await _setAvatarPending(false);
    try {
      final ok = await _updateOwnProfile({'avatar_url': value});
      if (!ok) return "Saved on this phone, but your profile couldn't be updated yet. Try again in a minute.";
      return null;
    } catch (e) {
      return "Saved on this phone, but other people can't see it yet: ${_friendlySendError(e)}";
    }
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
