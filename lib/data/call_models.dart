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
