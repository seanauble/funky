/// A named group chat with several friends (supabase/phase11.sql).
class GroupChat {
  final String id;
  final String name;
  // Everyone in the group; your own id shows up as 'me'.
  final List<String> memberIds;
  final String createdBy; // 'me' if you made it
  final DateTime createdAt;
  // The group's picture (a public URL), or null for the default icon.
  final String? photoUrl;
  // Who joined and who added them (oldest first) — drives the
  // "@sean added @alex" lines in the chat.
  final List<GroupJoin> joins;

  const GroupChat({
    required this.id,
    required this.name,
    required this.memberIds,
    required this.createdBy,
    required this.createdAt,
    this.photoUrl,
    this.joins = const [],
  });

  /// The chat room key its messages live under.
  String get room => 'grp_$id';
}

/// One person joining a group: [userId] (or 'me') and who added them.
class GroupJoin {
  final String userId;
  final String? addedBy; // 'me', a user id, or null if unknown
  final DateTime at;
  const GroupJoin({required this.userId, required this.addedBy, required this.at});
}

/// A centered system line in a group chat, e.g. "@sean added @alex".
class GroupEvent {
  final DateTime at;
  final String text;
  const GroupEvent({required this.at, required this.text});
}
