// Ports the prototype's reset logic (rule 2: "Everything social resets at
// 4 PM local time every day") so it's real logic from day one, not just a
// label in the UI. A real backend will eventually enforce this per time
// zone server-side (see HANDOFF's "What the owner wants next" #2) — this
// client-side version is what the mock store uses until then.

const RESET_HOUR = 16; // 4 PM, local time

/// The date (YYYY-MM-DD) of the most recent 4 PM. Every tonight-only record
/// carries this key; anything whose key doesn't match the current one is
/// treated as cleared, which is how the reset works without a server.
export function sessionKey(now: Date = new Date()): string {
  const d = new Date(now);
  if (d.getHours() < RESET_HOUR) {
    d.setDate(d.getDate() - 1);
  }
  return d.toISOString().slice(0, 10);
}

/// A friendly "2h 14m" countdown to the next reset, for the Home screen
/// footer ("Chat, Stories, places and polls are wiped at 4 PM. Next fresh
/// start in …").
export function untilReset(now: Date = new Date()): string {
  const next = new Date(now);
  next.setHours(RESET_HOUR, 0, 0, 0);
  if (next.getTime() <= now.getTime()) next.setDate(next.getDate() + 1);
  const ms = next.getTime() - now.getTime();
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  if (h <= 0) return `${m}m`;
  return `${h}h ${m}m`;
}

export function isCurrentSession(session: string, now: Date = new Date()): boolean {
  return session === sessionKey(now);
}
