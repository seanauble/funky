/// A named group chat with several friends (supabase/phase11.sql).
class GroupChat {
  final String id;
  final String name;
  // Everyone in the group; your own id shows up as 'me'.
  final List<String> memberIds;
  final String createdBy; // 'me' if you made it
  final DateTime createdAt;

  const GroupChat({
    required this.id,
    required this.name,
    required this.memberIds,
    required this.createdBy,
    required this.createdAt,
  });

  /// The chat room key its messages live under.
  String get room => 'grp_$id';
}
