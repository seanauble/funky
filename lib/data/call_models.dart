/// A video call that is ringing for you (supabase/phase13.sql).
class IncomingCall {
  final String id;
  // The caller's person id.
  final String fromId;
  final DateTime at;
  const IncomingCall({required this.id, required this.fromId, required this.at});
}

/// What the call-token function hands back: where to connect and the
/// short-lived key for this one call.
class CallCredentials {
  final String url;
  final String token;
  const CallCredentials({required this.url, required this.token});
}

/// A row of the calls table, as far as the call screens care.
class CallInfo {
  final String id;
  final String callerId; // 'me' when it's you
  final String calleeId; // 'me' when it's you
  final String status; // ringing | accepted | declined | cancelled | missed | ended
  final DateTime createdAt;
  const CallInfo({required this.id, required this.callerId, required this.calleeId, required this.status, required this.createdAt});

  bool get isLive => status == 'ringing' || status == 'accepted';
}

String _clockLength(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// One video call between you and a friend, as it shows up in your DM with
/// them: who started it and how it went.
class CallLogEntry {
  final String id;
  final String peerId; // the other person
  final bool outgoing; // you rang them
  // answered | missed | declined | live | ringing
  final String outcome;
  final DateTime at;
  final Duration? length;

  const CallLogEntry({
    required this.id,
    required this.peerId,
    required this.outgoing,
    required this.outcome,
    required this.at,
    this.length,
  });

  String title(String? peerHandle) => outgoing ? 'You started a video chat' : '@${peerHandle ?? 'someone'} started a video chat';

  String get subtitle {
    switch (outcome) {
      case 'answered':
        return length == null ? 'Call ended' : 'Call lasted ${_clockLength(length!)}';
      case 'live':
        return 'In progress';
      case 'ringing':
        return outgoing ? 'Calling…' : 'Ringing…';
      case 'declined':
        return outgoing ? 'Declined' : 'You declined';
      default:
        return outgoing ? 'No answer' : 'Missed call';
    }
  }

  /// A call you didn't pick up gets flagged red.
  bool get missedByYou => !outgoing && outcome == 'missed';

  static CallLogEntry? fromRow(Map<String, dynamic> row, String myId) {
    final id = row['id'] as String?;
    final caller = row['caller_id'] as String?;
    final callee = row['callee_id'] as String?;
    if (id == null || caller == null || callee == null) return null;
    final outgoing = caller == myId;
    final created = DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    final answered = DateTime.tryParse((row['answered_at'] as String?) ?? '')?.toLocal();
    final ended = DateTime.tryParse((row['ended_at'] as String?) ?? '')?.toLocal();
    final status = (row['status'] as String?) ?? 'ended';
    final age = DateTime.now().difference(created);

    String outcome;
    Duration? length;
    switch (status) {
      case 'ringing':
        // A ring that nobody answered within a minute and a bit is a miss.
        outcome = age > const Duration(seconds: 75) ? 'missed' : 'ringing';
      case 'accepted':
        if (ended == null && answered != null && age < const Duration(hours: 3)) {
          outcome = 'live';
        } else {
          outcome = 'answered';
          if (answered != null && ended != null) length = ended.difference(answered);
        }
      case 'ended':
        outcome = 'answered';
        if (answered != null && ended != null) length = ended.difference(answered);
      case 'declined':
        outcome = 'declined';
      default: // cancelled | missed
        outcome = 'missed';
    }
    return CallLogEntry(
      id: id,
      peerId: outgoing ? callee : caller,
      outgoing: outgoing,
      outcome: outcome,
      at: created,
      length: length,
    );
  }
}

/// A video call someone started in a group chat.
class GroupCallLogEntry {
  final String id;
  final String groupId;
  final String startedBy; // 'me' or a person id
  final DateTime at;
  final bool live;
  final Duration? length;

  const GroupCallLogEntry({
    required this.id,
    required this.groupId,
    required this.startedBy,
    required this.at,
    required this.live,
    this.length,
  });

  String title(String? starterHandle) => startedBy == 'me' ? 'You started a video call' : '@${starterHandle ?? 'someone'} started a video call';

  String get subtitle => live ? 'In progress' : (length == null ? 'Call ended' : 'Lasted ${_clockLength(length!)}');

  static GroupCallLogEntry? fromRow(Map<String, dynamic> row, String myId) {
    final id = row['id'] as String?;
    final gid = row['group_id'] as String?;
    final by = row['started_by'] as String?;
    if (id == null || gid == null || by == null) return null;
    final created = DateTime.tryParse((row['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
    final ended = DateTime.tryParse((row['ended_at'] as String?) ?? '')?.toLocal();
    final lastActive = DateTime.tryParse((row['last_active_at'] as String?) ?? '')?.toLocal();
    final status = (row['status'] as String?) ?? 'ended';
    final stillGoing = status == 'active' && lastActive != null && DateTime.now().difference(lastActive) < const Duration(minutes: 2);
    final end = ended ?? lastActive;
    return GroupCallLogEntry(
      id: id,
      groupId: gid,
      startedBy: by == myId ? 'me' : by,
      at: created,
      live: stillGoing,
      length: end == null ? null : end.difference(created),
    );
  }
}
