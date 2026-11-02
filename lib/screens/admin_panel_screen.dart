import 'dart:async';
import '../widgets/ios_ui.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/media_cache.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../data/place_photo.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'add_friends_screen.dart';
import 'person_profile_screen.dart';
import 'profile_parts.dart' show storyMedia, storyHasVideo;
import 'venue_review_screen.dart';

/// Reached from Settings, only ever shown to the one hardcoded FUNKY Admin
/// account (store.isAdmin — see app_store.dart) — a single place for the
/// moderation actions that used to be scattered one-at-a-time across
/// Places/Chat/a person's own profile: ban/unban a user (via search),
/// delete a place, delete a poll, and a one-tap "max out my points" for
/// testing the points/levels/badges UI without actually grinding for it.
class AdminPanelScreen extends StatelessWidget {
  const AdminPanelScreen({super.key});

  Future<void> _confirmDelete(
    BuildContext context,
    ThemeTokens tokens, {
    required String title,
    required String body,
    required VoidCallback onConfirm,
    String confirmLabel = 'Delete',
  }) async {
    final confirmed = await showIosDialog<bool>(
      context: context,
      builder: (dialogContext) => IosAlert(
        backgroundColor: tokens.surface,
        title: Text(title, style: TextStyle(color: tokens.ink)),
        content: Text(body, style: TextStyle(color: tokens.mute)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) onConfirm();
  }

  /// Tests every table/function the app depends on and lists what's missing,
  /// so "check your connection" never hides a SQL file that wasn't run.
  Future<void> _runBackendCheck(BuildContext context, ThemeTokens tokens, AppStore store) async {
    showIosDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator.adaptive()),
    );
    final results = await store.checkBackend();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    final allOk = results.every((r) => r.$2);
    await showIosDialog<void>(
      context: context,
      builder: (dialogContext) => IosAlert(
        backgroundColor: tokens.surface,
        title: Text(allOk ? 'Backend is set up ✓' : 'Backend needs attention', style: TextStyle(color: tokens.ink)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in results)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r.$2 ? '✅' : '❌'} ${r.$1}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                      if (!r.$2 && r.$3.isNotEmpty) Text(r.$3, style: TextStyle(color: tokens.mute, fontSize: 11.5)),
                    ],
                  ),
                ),
              if (!allOk)
                Text(
                  'Run supabase/RUN_ALL.sql in the Supabase SQL Editor, then check again.',
                  style: TextStyle(color: tokens.brand, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    if (!store.isAdmin) {
      // Shouldn't be reachable — Settings only ever links here for an
      // admin account in the first place — but guard anyway rather than
      // trust the caller.
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('FUNKY Admin')),
        body: Padding(padding: const EdgeInsets.all(20), child: Text('Admin only.', style: TextStyle(color: tokens.ink))),
      );
    }

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('FUNKY Admin')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const SectionHeader(title: 'Your account'),
          FunkyCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('Points: ${store.me.points}', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: store.maxOutMyPoints,
                  child: Text('Max out', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const SectionHeader(title: 'Backend'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => _runBackendCheck(context, tokens, store),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('Check backend setup', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                    Icon(Icons.fact_check_outlined, color: tokens.mute),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader(title: 'Users'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddFriendsScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Find a user to ban/unban', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    Icon(Icons.search, color: tokens.mute),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'To give someone points or ban them, open their profile → ••• → Manage this account.',
              style: TextStyle(color: tokens.mute, fontSize: 12.5),
            ),
          ),
          if (store.allBannedIds.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: EmptyNote(text: 'No one is banned right now.'))
          else
            ...store.allBannedIds.map((id) {
              final handle = store.personById(id)?.handle ?? id;
              return FunkyCard(
                margin: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Expanded(child: Text('@$handle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                    TextButton(
                      onPressed: () => store.unbanUser(id),
                      child: Text('Unban', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              );
            }),
          const SectionHeader(title: 'New venues'),
          FunkyCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VenueReviewScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.local_bar_outlined, color: tokens.brand),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Review bars & clubs to add', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                          Text(
                            store.venueCandidatesLoaded
                                ? '${store.venueCandidates.where((v) => v.status == 'pending').length} waiting · within 50 mi of Egg Harbor'
                                : 'Within 50 miles of Egg Harbor',
                            style: TextStyle(color: tokens.mute, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: tokens.mute),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader(title: 'Approvals'),
          Builder(builder: (context) {
            final pendingPlaces = store.places.where((p) => !store.isAdminVerified(p.id)).length;
            Widget count(String label, int n) => Expanded(
                  child: Column(
                    children: [
                      Text('$n', style: TextStyle(color: n > 0 ? tokens.orange : tokens.mute, fontWeight: FontWeight.w800, fontSize: 22)),
                      const SizedBox(height: 2),
                      Text(label, textAlign: TextAlign.center, style: TextStyle(color: tokens.mute, fontSize: 11.5)),
                    ],
                  ),
                );
            return FunkyCard(
              child: Row(
                children: [
                  count('Places to verify', pendingPlaces),
                  count('Pictures', store.pendingPhotoSuggestions.length),
                  count('Profile reports', store.openProfileReports.length),
                  count('Story reports', store.openStoryReports.length),
                ],
              ),
            );
          }),
          const SectionHeader(title: 'Places to verify'),
          Builder(builder: (context) {
            final unverified = store.places.where((p) => !store.isAdminVerified(p.id)).toList();
            if (unverified.isEmpty) return const EmptyNote(text: 'Every place is verified.');
            return Column(
              children: [
                for (final p in unverified)
                  FunkyCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                              Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 12)),
                              Text(
                                '${store.venueConfirmationCount(p.id)} of ${AppStore.venueVerificationThreshold} confirmations',
                                style: TextStyle(color: tokens.mute, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => store.setAdminVerified(p.id, true),
                          child: Text('Verify', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                        ),
                        IconButton(
                          onPressed: () => _confirmDelete(
                            context,
                            tokens,
                            title: 'Reject ${p.name}?',
                            body: 'This permanently removes this place, its reports, and its confirmations for everyone.',
                            confirmLabel: 'Reject',
                            onConfirm: () => store.deletePlace(p.id),
                          ),
                          icon: Icon(Icons.close, color: tokens.danger),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          }),
          SectionHeader(title: 'Place pictures to review (${store.pendingPhotoSuggestions.length})'),
          if (store.pendingPhotoSuggestions.isEmpty)
            const EmptyNote(text: 'No pictures waiting for approval.')
          else
            ...store.pendingPhotoSuggestions.map((sug) {
              final placeName = store.places.where((p) => p.id == sug.placeId).map((p) => p.name).firstOrNull ?? 'a place';
              final who = store.personById(sug.userId)?.handle;
              return FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(placeName, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    if (who != null) Text('from @$who', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: 180,
                        width: double.infinity,
                        child: netImage(
                          sug.url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: tokens.raised,
                            alignment: Alignment.center,
                            child: Text("Couldn't load this picture", style: TextStyle(color: tokens.mute)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => store.reviewPlacePhoto(sug.id, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: tokens.brand,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: Text('Approve', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => store.reviewPlacePhoto(sug.id, false),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: tokens.line),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: Text('Reject', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          SectionHeader(title: 'Profile reports (${store.openProfileReports.length})'),
          if (store.openProfileReports.isEmpty)
            const EmptyNote(text: 'No open profile reports.')
          else
            ...store.openProfileReports.map((r) {
              final reportedHandle = store.personById(r.reportedId)?.handle ?? 'unknown';
              final reporterHandle = store.personById(r.reporterId)?.handle ?? 'unknown';
              final alreadyBanned = store.isBanned(r.reportedId);
              return FunkyCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@$reportedHandle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(r.reason, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
                    Text('reported by @$reporterHandle', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: r.reportedId)),
                          ),
                          style: OutlinedButton.styleFrom(side: BorderSide(color: tokens.line)),
                          child: Text('View profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                        ),
                        if (!alreadyBanned)
                          OutlinedButton(
                            onPressed: () => _confirmDelete(
                              context,
                              tokens,
                              title: 'Ban @$reportedHandle?',
                              body: 'They lose access to posting, chat and messages, and the report is closed.',
              confirmLabel: 'Ban',
                              onConfirm: () {
                                store.banUser(r.reportedId);
                                store.resolveProfileReport(r.id);
                              },
                            ),
                            style: OutlinedButton.styleFrom(side: BorderSide(color: tokens.danger)),
                            child: Text('Ban', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
                          ),
                        TextButton(
                          onPressed: () => store.resolveProfileReport(r.id),
                          child: Text('Dismiss', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          SectionHeader(title: 'Reported stories & posts (${store.openStoryReports.length})'),
          if (store.openStoryReports.isEmpty)
            const EmptyNote(text: 'Nothing reported right now.')
          else
            ...store.openStoryReports.map((r) => _StoryReportCard(
                  report: r,
                  tokens: tokens,
                  onConfirm: (title, body, label, action) => _confirmDelete(
                    context,
                    tokens,
                    title: title,
                    body: body,
                    confirmLabel: label,
                    onConfirm: action,
                  ),
                )),
          const _CrashReportsSection(),
          const SectionHeader(title: 'All places'),
          if (store.places.isEmpty)
            const EmptyNote(text: 'No places right now.')
          else
            ...store.places.map((p) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                            Text(p.address, style: TextStyle(color: tokens.mute, fontSize: 12)),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => _confirmDelete(
                          context,
                          tokens,
                          title: 'Delete ${p.name}?',
                          body: 'This permanently removes this place, its reports, and its confirmations for everyone.',
                          onConfirm: () => store.deletePlace(p.id),
                        ),
                        icon: Icon(Icons.delete_outline, color: tokens.danger),
                      ),
                    ],
                  ),
                )),
          const SectionHeader(title: 'Polls'),
          if (store.polls.isEmpty)
            const EmptyNote(text: 'No polls right now.')
          else
            ...store.polls.map((poll) => FunkyCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(child: Text(poll.q, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700))),
                      IconButton(
                        onPressed: () => _confirmDelete(
                          context,
                          tokens,
                          title: 'Delete this poll?',
                          body: 'This permanently removes "${poll.q}" and everyone\'s votes on it.',
                          onConfirm: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final err = await store.deletePoll(poll.id);
                            messenger.showSnackBar(SnackBar(content: Text(err ?? 'Poll deleted.')));
                          },
                        ),
                        icon: Icon(Icons.delete_outline, color: tokens.danger),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}


/// One reported Story in the admin panel: a copy of it (tap to see it
/// big), who really posted it (even when anonymous), why it was reported,
/// and what to do about it.
class _StoryReportCard extends StatelessWidget {
  final StoryReport report;
  final ThemeTokens tokens;
  final void Function(String title, String body, String confirmLabel, VoidCallback action) onConfirm;
  const _StoryReportCard({required this.report, required this.tokens, required this.onConfirm});

  Future<void> _resolve(BuildContext context, AppStore store, {required bool remove}) async {
    final messenger = ScaffoldMessenger.of(context);
    final err = await store.resolveStoryReport(report, remove: remove);
    messenger.showSnackBar(SnackBar(content: Text(err ?? (remove ? 'Story removed.' : 'Report dismissed.'))));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final posterId = report.posterId;
    final poster = posterId == null ? null : store.personById(posterId);
    final posterHandle = poster?.handle ?? 'unknown';
    final reporters = report.reporterIds.map((id) => '@${store.personById(id)?.handle ?? 'someone'}').toList();
    final n = report.reportIds.length;
    final alreadyBanned = posterId != null && store.isBanned(posterId);
    Story? live;
    final sid = report.storyId;
    if (sid != null) {
      for (final s in store.stories) {
        if (s.id == sid) {
          live = s;
          break;
        }
      }
    }
    final posted = report.storyCreatedAt;
    final where = report.storyPlaceName;
    final caption = report.storyText?.trim();
    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => _ReportedStoryView(report: report, live: live),
                )),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 78, height: 112, child: _ReportedStoryThumb(report: report, live: live, tokens: tokens)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('@$posterHandle', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(999)),
                          child: Text(report.isPost ? 'Post' : 'Story', style: TextStyle(color: tokens.ink, fontSize: 10.5, fontWeight: FontWeight.w800)),
                        ),
                        if (report.storyAnon)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(999)),
                            child: Text('posted anonymously', style: TextStyle(color: tokens.mute, fontSize: 10.5, fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(report.reasons.join(' · '), style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${n == 1 ? '1 report' : '$n reports'} · ${reporters.take(3).join(', ')}${reporters.length > 3 ? '…' : ''}',
                      style: TextStyle(color: tokens.mute, fontSize: 12),
                    ),
                    if (posted != null || (where != null && where.isNotEmpty))
                      Text(
                        [
                          if (posted != null) 'Posted ${timeAgoLabel(posted.millisecondsSinceEpoch)}',
                          if (where != null && where.isNotEmpty) '📍 $where',
                        ].join(' · '),
                        style: TextStyle(color: tokens.mute, fontSize: 12),
                      ),
                    if (caption != null && caption.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('"$caption"', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontSize: 12.5)),
                      ),
                    if (!report.isPost && sid != null && live == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('No longer up (expired or deleted)', style: TextStyle(color: tokens.mute, fontSize: 11.5, fontStyle: FontStyle.italic)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: () => onConfirm(
                  report.isPost ? 'Remove this post?' : 'Remove this story?',
                  "It's deleted for everyone, @$posterHandle gets told it broke the rules, and the report is closed.",
                  'Remove',
                  () => _resolve(context, store, remove: true),
                ),
                style: OutlinedButton.styleFrom(side: BorderSide(color: tokens.danger)),
                child: Text(report.isPost ? 'Remove post' : 'Remove story', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
              ),
              if (posterId != null && posterId != 'me' && !alreadyBanned)
                OutlinedButton(
                  onPressed: () => onConfirm(
                    'Ban @$posterHandle?',
                    'They lose access to posting, chat and messages. The story is removed and the report is closed.',
                    'Ban',
                    () {
                      store.banUser(posterId);
                      _resolve(context, store, remove: true);
                    },
                  ),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: tokens.danger)),
                  child: Text('Ban poster', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w800)),
                ),
              if (posterId != null && posterId != 'me')
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: posterId)),
                  ),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: tokens.line)),
                  child: Text('View profile', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                ),
              TextButton(
                onPressed: () => _resolve(context, store, remove: false),
                child: Text('Dismiss', style: TextStyle(color: tokens.brand, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The small picture of a reported Story: the live Story if it's still
/// loaded here, otherwise the saved copy from storage, otherwise its text.
class _ReportedStoryThumb extends StatelessWidget {
  final StoryReport report;
  final Story? live;
  final ThemeTokens tokens;
  const _ReportedStoryThumb({required this.report, required this.live, required this.tokens});

  Widget _text() => Container(
        color: tokens.raised,
        padding: const EdgeInsets.all(6),
        alignment: Alignment.center,
        child: Text(
          report.storyText?.isNotEmpty == true ? report.storyText! : 'No picture',
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(color: tokens.ink, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = live;
    final path = report.storyMediaPath;
    if (s != null && (s.imageUrl != null || storyHasVideo(s) || (s.imagePath != null && File(s.imagePath!).existsSync()) || path == null)) {
      return Stack(fit: StackFit.expand, children: [
        storyMedia(s, tokens),
        if (storyHasVideo(s)) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 28)),
      ]);
    }
    if (path == null) return _text();
    final store = context.read<AppStore>();
    // A reported post's photo is in the public posts bucket.
    if (report.isPost) {
      return netImage(store.postPhotoUrl(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _text());
    }
    return FutureBuilder<String?>(
      future: store.storyPreviewUrl(path),
      initialData: store.cachedStoryPreviewUrl(path),
      builder: (context, snap) {
        if (!snap.hasData && snap.connectionState != ConnectionState.done) {
          return Container(
            color: tokens.raised,
            alignment: Alignment.center,
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.mute)),
          );
        }
        final url = snap.data;
        if (url == null) return _text();
        return Stack(fit: StackFit.expand, children: [
          if (report.storyIsVideo)
            VideoFrameThumbnail(url: url)
          else
            netImage(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _text()),
          if (report.storyIsVideo) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 28)),
        ]);
      },
    );
  }
}

/// Full-screen look at a reported Story (photo, video or text).
class _ReportedStoryView extends StatefulWidget {
  final StoryReport report;
  final Story? live;
  const _ReportedStoryView({required this.report, required this.live});

  @override
  State<_ReportedStoryView> createState() => _ReportedStoryViewState();
}

class _ReportedStoryViewState extends State<_ReportedStoryView> {
  VideoPlayerController? _video;
  String? _url;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppStore>();
    final live = widget.live;
    String? localVideo;
    String? url;
    bool isVideo = widget.report.storyIsVideo;
    if (live != null) {
      isVideo = storyHasVideo(live);
      final lp = isVideo ? live.videoPath : live.imagePath;
      if (lp != null && File(lp).existsSync()) {
        if (isVideo) localVideo = lp;
      }
      url = isVideo ? live.videoUrl : live.imageUrl;
    }
    final path = widget.report.storyMediaPath;
    if (url == null && localVideo == null && path != null) {
      url = widget.report.isPost ? store.postPhotoUrl(path) : await store.storyPreviewUrl(path);
    }
    if (!mounted) return;
    if (isVideo && (localVideo != null || url != null)) {
      final c = await openVideoController(path: localVideo, url: url);
      if (!mounted) {
        unawaited(c.dispose());
        return;
      }
      _video = c;
      try {
        await c.initialize();
        await c.setLooping(true);
        await c.play();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _url = url;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    final video = _video;
    Widget body;
    if (_loading) {
      body = const CircularProgressIndicator(color: Colors.white54);
    } else if (video != null && video.value.isInitialized) {
      body = AspectRatio(aspectRatio: video.value.aspectRatio, child: VideoPlayer(video));
    } else if (live != null && live.imagePath != null && File(live.imagePath!).existsSync()) {
      body = Image.file(File(live.imagePath!), fit: BoxFit.contain);
    } else if (_url != null && !widget.report.storyIsVideo) {
      body = netImage(_url!, fit: BoxFit.contain);
    } else {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.report.storyText?.isNotEmpty == true ? widget.report.storyText! : "The picture isn't available anymore.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
        ),
      );
    }
    final caption = widget.report.storyText?.trim();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(widget.report.isPost ? 'Reported post' : 'Reported story')),
      body: Column(
        children: [
          Expanded(child: Center(child: body)),
          if (caption != null && caption.isNotEmpty && (video != null || _url != null || live?.imagePath != null))
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(caption, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ),
        ],
      ),
    );
  }
}


/// Errors testers' phones hit (phase 32), grouped by message, newest first.
/// Tap one to see where it happened.
class _CrashReportsSection extends StatelessWidget {
  const _CrashReportsSection();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    if (!store.crashReportsLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.fetchCrashReports());
    }
    // Group the same error together.
    final groups = <String, List<CrashReport>>{};
    for (final r in store.crashReports) {
      (groups[r.message] ??= []).add(r);
    }
    final keys = groups.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Crash reports (${store.crashReports.length})',
          action: store.crashReports.isEmpty ? 'Refresh' : 'Clear all',
          onAction: store.crashReports.isEmpty
              ? () => store.fetchCrashReports()
              : () async {
                  final ok = await showIosDialog<bool>(
                    context: context,
                    builder: (d) => IosAlert(
                      backgroundColor: tokens.surface,
                      title: Text('Clear all crash reports?', style: TextStyle(color: tokens.ink)),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.of(d).pop(true), child: Text('Clear', style: TextStyle(color: tokens.danger))),
                      ],
                    ),
                  );
                  if (ok == true) await store.clearCrashReports();
                },
        ),
        if (keys.isEmpty)
          EmptyNote(text: store.crashReportsLoaded ? 'No errors reported. 🎉' : 'Loading…')
        else
          for (final k in keys.take(40))
            Builder(builder: (context) {
              final list = groups[k]!;
              final latest = list.first;
              final builds = {for (final r in list) if (r.build != null) r.build!}.toList()..sort();
              return FunkyCard(
                margin: const EdgeInsets.only(bottom: 8),
                padding: EdgeInsets.zero,
                child: InkWell(
                  onTap: () => showIosDialog<void>(
                    context: context,
                    builder: (d) => IosAlert(
                      backgroundColor: tokens.surface,
                      title: Text(latest.fatal ? 'Crash' : 'Error', style: TextStyle(color: tokens.ink)),
                      content: SingleChildScrollView(
                        child: SelectableText(
                          [
                            latest.message,
                            if (latest.context != null) '\nWhere: ${latest.context}',
                            '\nBuild ${latest.build ?? '?'} · ${latest.platform ?? ''}',
                            if (latest.stack != null) '\n${latest.stack}',
                          ].join('\n'),
                          style: TextStyle(color: tokens.ink, fontSize: 12, fontFamily: 'Courier'),
                        ),
                      ),
                      actions: [TextButton(onPressed: () => Navigator.of(d).pop(), child: const Text('Close'))],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(latest.fatal ? Icons.error_outline : Icons.warning_amber_rounded, color: latest.fatal ? tokens.danger : tokens.orange, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(latest.message, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                              const SizedBox(height: 3),
                              Text(
                                '${list.length}× · last ${timeAgoLabel(latest.at.millisecondsSinceEpoch)} · build ${builds.join(', ')}',
                                style: TextStyle(color: tokens.mute, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
      ],
    );
  }
}
