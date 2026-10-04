/// Connection info for FUNKY's real backend (Supabase) — see
/// supabase/schema.sql for the database schema this points at, and
/// main.dart for where this gets handed to Supabase.initialize().
///
/// Safe to commit: the publishable (anon) key is MEANT to ship inside
/// client apps — Supabase's security model is that every table it can
/// touch is locked down by the Row Level Security policies in
/// schema.sql, not by keeping this key secret. That's different from the
/// project's database password / direct Postgres connection string
/// (shown once in the Supabase dashboard when the project was created),
/// which grants full admin access with no RLS at all and must NEVER go
/// in this file, anywhere else in the app, or in git — it's only ever
/// used directly in the Supabase dashboard's SQL Editor, never by the
/// app itself.
class SupabaseConfig {
  static const url = 'https://jyjrcnncjskapoyenfld.supabase.co';
  static const publishableKey = 'sb_publishable_k-DfytvOHQlopYlH7qSOWQ_uydy633W';
}
