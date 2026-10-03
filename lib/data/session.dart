/// Ports the prototype's reset logic (rule 2: "Everything social resets at
/// 2 PM local time every day") so it's real logic from day one, not just a
/// label in the UI. A real backend will eventually enforce this per time
/// zone server-side (see HANDOFF's "What the owner wants next" #2) — this
/// client-side version is what the mock store uses until then.
library;

const resetHour = 14; // 2 PM, local time

String _pad2(int n) => n.toString().padLeft(2, '0');

/// The date (YYYY-MM-DD) of the most recent 2 PM. Every tonight-only record
/// carries this key; anything whose key doesn't match the current one is
/// treated as cleared, which is how the reset works without a server.
String sessionKey([DateTime? now]) {
  var d = now ?? DateTime.now();
  if (d.hour < resetHour) {
    d = d.subtract(const Duration(days: 1));
  }
  return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';
}

/// A friendly "2h 14m" countdown to the next reset, for the Home screen
/// footer ("Chat, Stories, places and polls are wiped at 2 PM. Next fresh
/// start in …").
String untilReset([DateTime? now]) {
  final n = now ?? DateTime.now();
  var next = DateTime(n.year, n.month, n.day, resetHour);
  if (!next.isAfter(n)) next = next.add(const Duration(days: 1));
  final diff = next.difference(n);
  final h = diff.inHours;
  final m = diff.inMinutes % 60;
  if (h <= 0) return '${m}m';
  return '${h}h ${m}m';
}

bool isCurrentSession(String session, [DateTime? now]) => session == sessionKey(now);
