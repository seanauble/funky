-- FUNKY: everything in one go (phase 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14). Paste ALL of this into the
-- Supabase SQL Editor and press Run. Safe to re-run.


-- ======================== phase2.sql ========================
-- FUNKY real-backend schema — Phase 2: go-live.
--
-- Run AFTER schema.sql (Phase 1). Open the Supabase dashboard for this
-- project -> SQL Editor -> paste this whole file -> Run. Safe to re-run:
-- every statement is IF NOT EXISTS / CREATE OR REPLACE / drop-and-recreate.
--
-- Adds: admin + ban plumbing, shared Places (+ confirmations), Live Chat,
-- polls + votes, place reports + confirmations, profile sync columns
-- (points bonus, going streak, name style, going-to), DM photo/video
-- columns + storage, avatars storage, rate-limit triggers, and the
-- realtime publication entries for all of it.

-- ============================================================
-- 0. Helper functions
-- ============================================================

-- The one hardcoded FUNKY Admin, matched on the signed-in email in the
-- caller's JWT.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'seanauble@icloud.com'
$$;

-- ============================================================
-- 1. Profiles: new columns, protection, admin flag
-- ============================================================

alter table public.profiles add column if not exists bonus_points integer not null default 0;
alter table public.profiles add column if not exists move text;
alter table public.profiles add column if not exists move_session text;
alter table public.profiles add column if not exists move_streak integer not null default 0;
alter table public.profiles add column if not exists move_streak_day text;
alter table public.profiles add column if not exists style jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists banned boolean not null default false;
alter table public.profiles add column if not exists is_admin boolean not null default false;

create or replace function public.is_banned()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select coalesce((select banned from public.profiles where id = auth.uid()), false)
$$;

-- Nobody but the admin can touch bonus_points / banned / is_admin on a
-- profile (everyone can still update their own handle/bio/points/etc).
create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  -- auth.uid() is null for the SQL editor / service role, which is allowed
  -- to change these (that's how the admin flag gets backfilled below).
  if auth.uid() is not null and not public.is_admin() then
    new.bonus_points := old.bonus_points;
    new.banned := old.banned;
    new.is_admin := old.is_admin;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_columns on public.profiles;
create trigger protect_profile_columns
  before update on public.profiles
  for each row execute procedure public.protect_profile_columns();

-- New accounts: the admin's own email gets the admin flag automatically.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, handle, is_admin)
  values (
    new.id,
    'funky_' || substr(new.id::text, 1, 8),
    lower(coalesce(new.email, '')) = 'seanauble@icloud.com'
  );
  return new;
end;
$$;

-- Backfill the admin flag for the account that already exists.
update public.profiles p
set is_admin = true
from auth.users u
where u.id = p.id and lower(u.email) = 'seanauble@icloud.com';

-- Admin-only actions, as functions so the rules live in one place.
create or replace function public.admin_give_points(target uuid, amount integer)
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  new_total integer;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.profiles
  set bonus_points = greatest(0, bonus_points + amount)
  where id = target
  returning bonus_points into new_total;
  return new_total;
end;
$$;

create or replace function public.admin_set_banned(target uuid, flag boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.profiles set banned = flag where id = target;
end;
$$;

grant execute on function public.admin_give_points(uuid, integer) to authenticated;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;

-- ============================================================
-- 2. Rate limiting — generic trigger: <= N rows per user per window.
--    The admin is exempt. Args: (user column, window seconds, max rows).
-- ============================================================

create or replace function public.rate_limit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  col text := tg_argv[0];
  secs integer := tg_argv[1]::integer;
  maxn integer := tg_argv[2]::integer;
  recent integer;
begin
  if public.is_admin() then
    return new;
  end if;
  execute format(
    'select count(*) from %I.%I where %I = $1 and created_at > now() - make_interval(secs => $2)',
    tg_table_schema, tg_table_name, col
  ) into recent using auth.uid(), secs;
  if recent >= maxn then
    raise exception 'rate limit exceeded';
  end if;
  return new;
end;
$$;

drop trigger if exists rate_limit_messages on public.messages;
create trigger rate_limit_messages before insert on public.messages
  for each row execute procedure public.rate_limit('sender_id', '60', '25');

drop trigger if exists rate_limit_stories on public.stories;
create trigger rate_limit_stories before insert on public.stories
  for each row execute procedure public.rate_limit('uid', '60', '10');

-- ============================================================
-- 3. Places (shared) + confirmations
-- ============================================================

create table if not exists public.places (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  kind text not null default 'area',
  lat double precision not null,
  lng double precision not null,
  address text not null default '' check (char_length(address) <= 80),
  by_uid uuid references public.profiles (id) on delete set null,
  admin_verified boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.places enable row level security;

drop policy if exists "Anyone signed in can see places" on public.places;
create policy "Anyone signed in can see places"
  on public.places for select to authenticated using (true);

drop policy if exists "Add a place as yourself" on public.places;
create policy "Add a place as yourself"
  on public.places for insert to authenticated
  with check (
    auth.uid() = by_uid
    and not public.is_banned()
    and (admin_verified = false or public.is_admin())
  );

drop policy if exists "Admin can verify places" on public.places;
create policy "Admin can verify places"
  on public.places for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admin or owner can delete a place" on public.places;
create policy "Admin or owner can delete a place"
  on public.places for delete to authenticated
  using (public.is_admin() or auth.uid() = by_uid);

drop trigger if exists rate_limit_places on public.places;
create trigger rate_limit_places before insert on public.places
  for each row execute procedure public.rate_limit('by_uid', '86400', '3');

create table if not exists public.place_confirmations (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

alter table public.place_confirmations enable row level security;

drop policy if exists "See place confirmations" on public.place_confirmations;
create policy "See place confirmations"
  on public.place_confirmations for select to authenticated using (true);

drop policy if exists "Confirm a place as yourself" on public.place_confirmations;
create policy "Confirm a place as yourself"
  on public.place_confirmations for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned());

drop policy if exists "Remove your confirmation or admin" on public.place_confirmations;
create policy "Remove your confirmation or admin"
  on public.place_confirmations for delete to authenticated
  using (auth.uid() = user_id or public.is_admin());

-- Unverified places only live for the night. A place stays if the admin
-- verified it or 15+ people confirmed it. Anyone's app can call this; it
-- only ever deletes places that are already stale.
create or replace function public.purge_stale_places()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  with doomed as (
    select p.id
    from public.places p
    where p.created_at < now() - interval '24 hours'
      and p.admin_verified = false
      and (select count(*) from public.place_confirmations c where c.place_id = p.id) < 15
  ),
  del as (
    delete from public.places where id in (select id from doomed) returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_stale_places() to authenticated;

-- ============================================================
-- 4. Live Chat. Anonymous messages are stored with a NULL sender (so
--    nobody inspecting traffic can see who sent them); a separate
--    admin-only table remembers the real author for moderation.
-- ============================================================

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid references public.profiles (id) on delete cascade,
  text text not null check (char_length(text) between 1 and 240),
  anon boolean not null default false,
  lat double precision,
  lng double precision,
  created_at timestamptz not null default now()
);

alter table public.chat_messages enable row level security;

drop policy if exists "Read tonight's live chat" on public.chat_messages;
create policy "Read tonight's live chat"
  on public.chat_messages for select to authenticated
  using (created_at > now() - interval '24 hours' or public.is_admin());

drop policy if exists "Post to live chat" on public.chat_messages;
create policy "Post to live chat"
  on public.chat_messages for insert to authenticated
  with check (
    not public.is_banned()
    and ((anon and sender_id is null) or (not anon and sender_id = auth.uid()))
  );

drop policy if exists "Admin or author can delete chat messages" on public.chat_messages;
create policy "Admin or author can delete chat messages"
  on public.chat_messages for delete to authenticated
  using (public.is_admin() or sender_id = auth.uid());

create table if not exists public.chat_message_authors (
  message_id uuid primary key references public.chat_messages (id) on delete cascade,
  uid uuid not null
);

alter table public.chat_message_authors enable row level security;

drop policy if exists "Only the admin sees chat authors" on public.chat_message_authors;
create policy "Only the admin sees chat authors"
  on public.chat_message_authors for select to authenticated
  using (public.is_admin());

create or replace function public.log_chat_author()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.chat_message_authors (message_id, uid) values (new.id, auth.uid());
  return new;
end;
$$;

drop trigger if exists chat_author_log on public.chat_messages;
create trigger chat_author_log after insert on public.chat_messages
  for each row execute procedure public.log_chat_author();

-- Live chat rate limit: 6 messages per 10 seconds per real author.
create or replace function public.chat_rate_limit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  recent integer;
begin
  if public.is_admin() then
    return new;
  end if;
  select count(*) into recent
  from public.chat_message_authors a
  join public.chat_messages m on m.id = a.message_id
  where a.uid = auth.uid() and m.created_at > now() - interval '10 seconds';
  if recent >= 6 then
    raise exception 'rate limit exceeded';
  end if;
  return new;
end;
$$;

drop trigger if exists chat_rate_limit on public.chat_messages;
create trigger chat_rate_limit before insert on public.chat_messages
  for each row execute procedure public.chat_rate_limit();

-- ============================================================
-- 5. Polls + votes
-- ============================================================

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  q text not null check (char_length(q) between 1 and 80),
  options text[] not null check (array_length(options, 1) between 2 and 8),
  lat double precision not null,
  lng double precision not null,
  by_uid uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.polls enable row level security;

drop policy if exists "See polls" on public.polls;
create policy "See polls" on public.polls for select to authenticated using (true);

drop policy if exists "Post a poll as yourself" on public.polls;
create policy "Post a poll as yourself" on public.polls for insert to authenticated
  with check (auth.uid() = by_uid and not public.is_banned());

drop policy if exists "Admin or owner can delete a poll" on public.polls;
create policy "Admin or owner can delete a poll" on public.polls for delete to authenticated
  using (public.is_admin() or auth.uid() = by_uid);

drop trigger if exists rate_limit_polls on public.polls;
create trigger rate_limit_polls before insert on public.polls
  for each row execute procedure public.rate_limit('by_uid', '86400', '3');

create table if not exists public.poll_votes (
  poll_id uuid not null references public.polls (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  option_idx integer not null check (option_idx >= 0 and option_idx < 8),
  created_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);

alter table public.poll_votes enable row level security;

drop policy if exists "See poll votes" on public.poll_votes;
create policy "See poll votes" on public.poll_votes for select to authenticated using (true);

drop policy if exists "Vote as yourself" on public.poll_votes;
create policy "Vote as yourself" on public.poll_votes for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned());

drop policy if exists "Change your own vote" on public.poll_votes;
create policy "Change your own vote" on public.poll_votes for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Remove your own vote" on public.poll_votes;
create policy "Remove your own vote" on public.poll_votes for delete to authenticated
  using (auth.uid() = user_id or public.is_admin());

-- ============================================================
-- 6. Place reports (cover / police / shutdown / line / capacity)
-- ============================================================

create table if not exists public.place_reports (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  kind text not null check (kind in ('cover', 'police', 'shutdown', 'line', 'capacity')),
  detail text check (detail is null or char_length(detail) <= 20),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.place_reports enable row level security;

drop policy if exists "See reports" on public.place_reports;
create policy "See reports" on public.place_reports for select to authenticated using (true);

drop policy if exists "Report as yourself" on public.place_reports;
create policy "Report as yourself" on public.place_reports for insert to authenticated
  with check (auth.uid() = reporter_id and not public.is_banned());

drop policy if exists "Retract your report or admin" on public.place_reports;
create policy "Retract your report or admin" on public.place_reports for delete to authenticated
  using (auth.uid() = reporter_id or public.is_admin());

drop trigger if exists rate_limit_reports on public.place_reports;
create trigger rate_limit_reports before insert on public.place_reports
  for each row execute procedure public.rate_limit('reporter_id', '3600', '12');

create table if not exists public.report_confirmations (
  report_id uuid not null references public.place_reports (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (report_id, user_id)
);

alter table public.report_confirmations enable row level security;

drop policy if exists "See report confirmations" on public.report_confirmations;
create policy "See report confirmations" on public.report_confirmations for select to authenticated using (true);

drop policy if exists "Confirm a report as yourself" on public.report_confirmations;
create policy "Confirm a report as yourself" on public.report_confirmations for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned());

drop policy if exists "Remove your report confirmation" on public.report_confirmations;
create policy "Remove your report confirmation" on public.report_confirmations for delete to authenticated
  using (auth.uid() = user_id or public.is_admin());

-- ============================================================
-- 7. DMs: photo/video + seen receipts
-- ============================================================

alter table public.messages add column if not exists media_path text;
alter table public.messages add column if not exists media_type text;
alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages alter column text set default '';

drop policy if exists "Send a message as yourself" on public.messages;
create policy "Send a message as yourself"
  on public.messages for insert to authenticated
  with check (auth.uid() = sender_id and not public.is_banned());

-- The recipient can mark messages as read — and ONLY that column.
drop policy if exists "Recipient marks messages read" on public.messages;
create policy "Recipient marks messages read"
  on public.messages for update to authenticated
  using (auth.uid() = recipient_id) with check (auth.uid() = recipient_id);

create or replace function public.messages_only_read_at()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.sender_id := old.sender_id;
  new.recipient_id := old.recipient_id;
  new.text := old.text;
  new.media_path := old.media_path;
  new.media_type := old.media_type;
  new.created_at := old.created_at;
  return new;
end;
$$;

drop trigger if exists messages_only_read_at on public.messages;
create trigger messages_only_read_at
  before update on public.messages
  for each row execute procedure public.messages_only_read_at();

-- Private bucket for DM photos/videos (25 MB per file). Uploads go under
-- "<your-user-id>/..."; the recipient can read a file once a message row
-- pointing at it exists.
insert into storage.buckets (id, name, public, file_size_limit)
values ('dm_media', 'dm_media', false, 26214400)
on conflict (id) do nothing;

drop policy if exists "Upload your own DM media" on storage.objects;
create policy "Upload your own DM media"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'dm_media' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Read DM media you sent or received" on storage.objects;
create policy "Read DM media you sent or received"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'dm_media'
    and (
      (storage.foldername(name)) [1] = auth.uid()::text
      or exists (
        select 1 from public.messages m
        where m.media_path = name and m.recipient_id = auth.uid()
      )
    )
  );

drop policy if exists "Delete your own DM media" on storage.objects;
create policy "Delete your own DM media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'dm_media' and (storage.foldername(name)) [1] = auth.uid()::text);

-- ============================================================
-- 8. Avatars (public read — a profile picture is visible to everyone)
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', true, 8388608)
on conflict (id) do nothing;

drop policy if exists "Upload your own avatar" on storage.objects;
create policy "Upload your own avatar"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Replace your own avatar" on storage.objects;
create policy "Replace your own avatar"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Read avatars" on storage.objects;
create policy "Read avatars"
  on storage.objects for select to authenticated
  using (bucket_id = 'avatars');

-- ============================================================
-- 9. Realtime publication entries (idempotent)
-- ============================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'places', 'place_confirmations', 'chat_messages',
    'polls', 'poll_votes', 'place_reports', 'report_confirmations'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ======================== phase3.sql ========================
-- ============================================================
-- FUNKY phase 3 — run once in the Supabase SQL Editor (after phase2.sql).
-- Adds: shared live-chat reactions, shared place cover photos.
-- Safe to re-run.
-- ============================================================

-- 1. Live-chat reactions (one reaction per person per message)

create table if not exists public.chat_reactions (
  message_id uuid not null references public.chat_messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.chat_reactions enable row level security;

drop policy if exists "See live chat reactions" on public.chat_reactions;
create policy "See live chat reactions"
  on public.chat_reactions for select to authenticated using (true);

drop policy if exists "React as yourself" on public.chat_reactions;
create policy "React as yourself"
  on public.chat_reactions for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists "Change your own reaction" on public.chat_reactions;
create policy "Change your own reaction"
  on public.chat_reactions for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists "Remove your own reaction" on public.chat_reactions;
create policy "Remove your own reaction"
  on public.chat_reactions for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop trigger if exists rate_limit_chat_reactions on public.chat_reactions;
create trigger rate_limit_chat_reactions before insert on public.chat_reactions
  for each row execute procedure public.rate_limit('user_id', '60', '60');

-- 2. Place cover photos

alter table public.places add column if not exists cover_url text;

insert into storage.buckets (id, name, public, file_size_limit)
values ('place_covers', 'place_covers', true, 8388608)
on conflict (id) do nothing;

drop policy if exists "Upload your own place cover" on storage.objects;
create policy "Upload your own place cover"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'place_covers' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Anyone can see place covers" on storage.objects;
create policy "Anyone can see place covers"
  on storage.objects for select to authenticated
  using (bucket_id = 'place_covers');

drop policy if exists "Delete your own place cover" on storage.objects;
create policy "Delete your own place cover"
  on storage.objects for delete to authenticated
  using (bucket_id = 'place_covers' and ((storage.foldername(name)) [1] = auth.uid()::text or public.is_admin()));

-- 3. Realtime

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_reactions'
  ) then
    alter publication supabase_realtime add table public.chat_reactions;
  end if;
end $$;

-- ======================== phase4.sql ========================
-- ============================================================
-- FUNKY phase 4 — run once in the Supabase SQL Editor.
-- New accounts get a random username (like NeonFox482) instead of
-- funky_1a2b3c4d, and existing placeholder names are replaced.
-- Safe to re-run.
-- ============================================================

create or replace function public.random_handle()
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  adjs text[] := array['Neon','Funky','Wild','Midnight','Electric','Cosmic','Sunny','Velvet','Turbo','Disco','Glitter','Lucky','Spicy','Groovy','Hyper','Chill'];
  nouns text[] := array['Fox','Panda','Tiger','Comet','Falcon','Otter','Raven','Llama','Gecko','Moose','Wolf','Koala','Dragon','Pixel','Rocket','Taco'];
  h text;
begin
  loop
    h := adjs[1 + floor(random() * array_length(adjs, 1))::int]
      || nouns[1 + floor(random() * array_length(nouns, 1))::int]
      || (100 + floor(random() * 900))::int::text;
    exit when not exists (select 1 from public.profiles where lower(handle) = lower(h));
  end loop;
  return h;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, handle, is_admin)
  values (
    new.id,
    public.random_handle(),
    lower(coalesce(new.email, '')) = 'seanauble@icloud.com'
  );
  return new;
end;
$$;

-- Replace the old placeholder names (funky_xxxxxxxx) on existing accounts.
do $$
declare
  r record;
begin
  for r in select id from public.profiles where handle ~ '^funky_[0-9a-f]{8}$'
  loop
    update public.profiles set handle = public.random_handle() where id = r.id;
  end loop;
end $$;

-- ======================== phase5.sql ========================
-- ============================================================
-- FUNKY phase 5 — delegated admins. Run after phase2.sql (RUN_ALL.sql
-- already includes it). Safe to re-run.
--   * The owner email is always admin.
--   * Anyone with profiles.is_admin = true is ALSO an admin everywhere
--     (ban, give points, verify/delete places, etc.).
--   * Only the owner can change someone else's admin flag.
-- ============================================================

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'seanauble@icloud.com'
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select public.is_owner()
      or coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  -- auth.uid() is null for the SQL editor / service role (allowed).
  if auth.uid() is not null then
    if not public.is_admin() then
      new.bonus_points := old.bonus_points;
      new.banned := old.banned;
    end if;
    if not public.is_owner() then
      new.is_admin := old.is_admin;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.admin_set_admin(target uuid, flag boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'owner only';
  end if;
  update public.profiles set is_admin = flag where id = target;
end;
$$;

grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;

-- Make @venuto an admin.
update public.profiles set is_admin = true where lower(handle) = 'venuto';

-- ======================== phase6.sql ========================
-- ============================================================
-- FUNKY phase 6 — repair + hardening. Run after phase 2-5 (RUN_ALL.sql
-- already includes it). Safe to re-run.
--   * Storage buckets for profile pictures / place photos are forced PUBLIC
--     (an older, private bucket is why other people couldn't see pictures).
--   * The "new account -> profile row" trigger is (re)installed, and every
--     existing account that never got a profile row gets one now.
--   * ensure_my_profile(): lets the app repair a missing profile row itself.
--   * backend_status(): what the in-app "Check backend setup" reads.
-- ============================================================

-- 1. Buckets: create OR fix. (`do nothing` used to leave a private bucket private.)

insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', true, 8388608)
on conflict (id) do update set public = true, file_size_limit = 8388608;

insert into storage.buckets (id, name, public, file_size_limit)
values ('place_covers', 'place_covers', true, 8388608)
on conflict (id) do update set public = true, file_size_limit = 8388608;

insert into storage.buckets (id, name, public, file_size_limit)
values ('dm_media', 'dm_media', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

-- 2. Sign-up trigger (re)installed, never fails a signup, never duplicates.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, handle, is_admin)
  values (
    new.id,
    public.random_handle(),
    lower(coalesce(new.email, '')) = 'seanauble@icloud.com'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- 3. Backfill: every account without a profile row gets one.
--    (Without a row, chat/places/polls/avatars all fail on a foreign key.)

do $$
declare
  r record;
begin
  for r in
    select u.id, u.email from auth.users u
    where not exists (select 1 from public.profiles p where p.id = u.id)
  loop
    insert into public.profiles (id, handle, is_admin)
    values (r.id, public.random_handle(), lower(coalesce(r.email, '')) = 'seanauble@icloud.com')
    on conflict (id) do nothing;
  end loop;
end $$;

-- The owner is always flagged admin on their own row too.
update public.profiles p set is_admin = true
from auth.users u
where u.id = p.id and lower(coalesce(u.email, '')) = 'seanauble@icloud.com' and not p.is_admin;

-- 4. The app can repair its own missing profile row.

create or replace function public.ensure_my_profile()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  insert into public.profiles (id, handle, is_admin)
  values (auth.uid(), public.random_handle(), em = 'seanauble@icloud.com')
  on conflict (id) do nothing;
end;
$$;

grant execute on function public.ensure_my_profile() to authenticated;

-- 5. One-call health report for the in-app checker.

create or replace function public.backend_status()
returns jsonb
language sql
stable
security definer set search_path = public
as $$
  select jsonb_build_object(
    'profile_exists', exists (select 1 from public.profiles where id = auth.uid()),
    'avatars_public', coalesce((select public from storage.buckets where id = 'avatars'), false),
    'place_covers_public', coalesce((select public from storage.buckets where id = 'place_covers'), false),
    'dm_media_exists', exists (select 1 from storage.buckets where id = 'dm_media'),
    'signup_trigger', exists (select 1 from pg_trigger where tgname = 'on_auth_user_created'),
    'accounts_without_profile', (select count(*) from auth.users u where not exists (select 1 from public.profiles p where p.id = u.id)),
    'placeholder_handles', (select count(*) from public.profiles where handle ~ '^funky_[0-9a-f]{8}$')
  )
$$;

grant execute on function public.backend_status() to authenticated;

-- 6. Admins can take points away too. The bonus can now go negative (down to
--    wherever the person's total hits 0) — before, it was floored at 0, so
--    removing points from someone with no gifted bonus did nothing.

create or replace function public.admin_give_points(target uuid, amount integer)
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  new_total integer;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  update public.profiles
  set bonus_points = greatest(-points, bonus_points + amount)
  where id = target
  returning bonus_points into new_total;
  return new_total;
end;
$$;

grant execute on function public.admin_give_points(uuid, integer) to authenticated;

-- ======================== phase7.sql ========================
-- ============================================================
-- PHASE 7 — Notifications (DMs, friend requests, new verified places
-- near you, reports at places you're going to).
--
-- Every notification is a row in `notifications`, created ONLY by the
-- triggers below (nobody can insert one by hand). The app shows them in
-- its bell screen; a Supabase Database Webhook on that table's INSERT
-- calls the `send-push` Edge Function, which delivers the iPhone push.
-- Safe to re-run.
-- ============================================================

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  title text not null default '',
  body text not null default '',
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists notifications_user_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "See your own notifications" on public.notifications;
create policy "See your own notifications"
  on public.notifications for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Mark your own notifications read" on public.notifications;
create policy "Mark your own notifications read"
  on public.notifications for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Delete your own notifications" on public.notifications;
create policy "Delete your own notifications"
  on public.notifications for delete to authenticated
  using (auth.uid() = user_id);

-- Only read_at may be changed by the app.
create or replace function public.notifications_only_read_at()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.id := old.id;
  new.user_id := old.user_id;
  new.kind := old.kind;
  new.title := old.title;
  new.body := old.body;
  new.data := old.data;
  new.created_at := old.created_at;
  return new;
end;
$$;

drop trigger if exists notifications_only_read_at on public.notifications;
create trigger notifications_only_read_at
  before update on public.notifications
  for each row execute procedure public.notifications_only_read_at();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ---- Which kinds of notification each person wants -----------------

create table if not exists public.notification_prefs (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  dm_on boolean not null default true,
  friend_on boolean not null default true,
  place_on boolean not null default true,
  report_on boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.notification_prefs enable row level security;

drop policy if exists "See your own notification prefs" on public.notification_prefs;
create policy "See your own notification prefs"
  on public.notification_prefs for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Add your own notification prefs" on public.notification_prefs;
create policy "Add your own notification prefs"
  on public.notification_prefs for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Change your own notification prefs" on public.notification_prefs;
create policy "Change your own notification prefs"
  on public.notification_prefs for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---- Phones that should receive pushes ------------------------------

create table if not exists public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null default 'ios',
  updated_at timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

drop policy if exists "See your own device tokens" on public.device_tokens;
create policy "See your own device tokens"
  on public.device_tokens for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Add your own device token" on public.device_tokens;
create policy "Add your own device token"
  on public.device_tokens for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Update your own device token" on public.device_tokens;
create policy "Update your own device token"
  on public.device_tokens for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Remove your own device token" on public.device_tokens;
create policy "Remove your own device token"
  on public.device_tokens for delete to authenticated
  using (auth.uid() = user_id);

-- A token moves with the phone: if someone else signs in on the same
-- phone, the token is re-pointed at them instead of colliding.
create or replace function public.register_device_token(p_token text, p_platform text default 'ios')
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first';
  end if;
  insert into public.device_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), coalesce(p_platform, 'ios'), now())
  on conflict (token) do update
    set user_id = auth.uid(), platform = excluded.platform, updated_at = now();
end;
$$;

grant execute on function public.register_device_token(text, text) to authenticated;

-- ---- Where each person last opened the app (private) ----------------
-- Used ONLY to decide who is within 25 miles of a newly verified place.
-- Not readable by anyone but the person themselves.

create table if not exists public.user_locations (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  updated_at timestamptz not null default now()
);

alter table public.user_locations enable row level security;

drop policy if exists "See your own location row" on public.user_locations;
create policy "See your own location row"
  on public.user_locations for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Add your own location row" on public.user_locations;
create policy "Add your own location row"
  on public.user_locations for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Update your own location row" on public.user_locations;
create policy "Update your own location row"
  on public.user_locations for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Delete your own location row" on public.user_locations;
create policy "Delete your own location row"
  on public.user_locations for delete to authenticated
  using (auth.uid() = user_id);

-- ---- The one function that creates a notification -------------------

create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  -- Housekeeping: this person's notifications older than 30 days go.
  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, coalesce(d, '{}'::jsonb));
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public.notif_handle(uid uuid)
returns text
language sql
stable
security definer set search_path = public
as $$
  select coalesce(nullif(handle, ''), 'someone') from public.profiles where id = uid;
$$;

revoke all on function public.notif_handle(uuid) from public, anon, authenticated;

-- ---- 1. Direct messages ---------------------------------------------

create or replace function public.notify_dm()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  who text;
  preview text;
begin
  who := public.notif_handle(new.sender_id);
  if new.media_path is not null and coalesce(new.text, '') = '' then
    preview := case when new.media_type = 'video' then 'Sent you a video' else 'Sent you a photo' end;
  else
    preview := left(coalesce(new.text, ''), 120);
  end if;
  perform public.push_notify(
    new.recipient_id, 'dm', '@' || who, preview,
    jsonb_build_object('from', new.sender_id, 'message_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists notify_dm on public.messages;
create trigger notify_dm after insert on public.messages
  for each row execute procedure public.notify_dm();

-- Reading a conversation clears its notifications.
create or replace function public.clear_dm_notifications()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.read_at is not null and old.read_at is null then
    update public.notifications
       set read_at = now()
     where user_id = new.recipient_id
       and kind = 'dm'
       and read_at is null
       and data ->> 'from' = new.sender_id::text;
  end if;
  return new;
end;
$$;

drop trigger if exists clear_dm_notifications on public.messages;
create trigger clear_dm_notifications after update of read_at on public.messages
  for each row execute procedure public.clear_dm_notifications();

-- ---- 2. Friend requests ---------------------------------------------

create or replace function public.notify_friend_insert()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.status = 'pending' then
    perform public.push_notify(
      new.addressee_id, 'friend', 'Friend request',
      '@' || public.notif_handle(new.requester_id) || ' wants to be friends',
      jsonb_build_object('from', new.requester_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists notify_friend_insert on public.friendships;
create trigger notify_friend_insert after insert on public.friendships
  for each row execute procedure public.notify_friend_insert();

create or replace function public.notify_friend_accept()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status = 'pending' then
    perform public.push_notify(
      new.requester_id, 'friend', 'Friend request accepted',
      '@' || public.notif_handle(new.addressee_id) || ' is now your friend',
      jsonb_build_object('from', new.addressee_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists notify_friend_accept on public.friendships;
create trigger notify_friend_accept after update of status on public.friendships
  for each row execute procedure public.notify_friend_accept();

-- ---- 3. A new verified place within 25 miles ------------------------

create or replace function public.notify_place_verified(pid uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pl public.places%rowtype;
  dlat double precision;
  dlng double precision;
begin
  select * into pl from public.places where id = pid;
  if not found then return; end if;

  -- 25 miles ≈ 0.363 degrees of latitude; longitude shrinks with latitude.
  dlat := 25.0 / 69.0;
  dlng := 25.0 / (69.172 * greatest(0.01, cos(radians(pl.lat))));

  insert into public.notifications (user_id, kind, title, body, data)
  select ul.user_id, 'place', 'New verified place near you',
         pl.name || ' is now verified on FUNKY',
         jsonb_build_object('place_id', pl.id)
    from public.user_locations ul
    left join public.notification_prefs np on np.user_id = ul.user_id
   where ul.user_id is distinct from pl.by_uid
     and coalesce(np.place_on, true)
     and ul.lat between pl.lat - dlat and pl.lat + dlat
     and ul.lng between pl.lng - dlng and pl.lng + dlng
     and 3958.8 * 2 * asin(least(1, sqrt(
           power(sin(radians(ul.lat - pl.lat) / 2), 2) +
           cos(radians(pl.lat)) * cos(radians(ul.lat)) *
           power(sin(radians(ul.lng - pl.lng) / 2), 2)
         ))) <= 25
     and not exists (
       select 1 from public.notifications n
        where n.user_id = ul.user_id
          and n.kind = 'place'
          and n.data ->> 'place_id' = pl.id::text
     );
end;
$$;

revoke all on function public.notify_place_verified(uuid) from public, anon, authenticated;

create or replace function public.notify_place_insert()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.admin_verified then
    perform public.notify_place_verified(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists notify_place_insert on public.places;
create trigger notify_place_insert after insert on public.places
  for each row execute procedure public.notify_place_insert();

create or replace function public.notify_place_update()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.admin_verified and not old.admin_verified then
    perform public.notify_place_verified(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists notify_place_update on public.places;
create trigger notify_place_update after update of admin_verified on public.places
  for each row execute procedure public.notify_place_update();

-- Or: the 15th person confirms it.
create or replace function public.notify_place_confirmed()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  select count(*) into n from public.place_confirmations where place_id = new.place_id;
  if n = 15 then
    perform public.notify_place_verified(new.place_id);
  end if;
  return new;
end;
$$;

drop trigger if exists notify_place_confirmed on public.place_confirmations;
create trigger notify_place_confirmed after insert on public.place_confirmations
  for each row execute procedure public.notify_place_confirmed();

-- ---- 4. A new report at a place you said you're going to -----------
-- profiles.move holds the place id you picked for tonight; move_session
-- is the night it was picked (the app's nights run 2 PM to 2 PM, so we
-- accept yesterday's or today's date to cover every time zone).

create or replace function public.notify_report()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  pname text;
  label text;
  what text;
begin
  select name into pname from public.places where id = new.place_id;
  if pname is null then return new; end if;

  label := case new.kind
    when 'cover' then 'Cover charge'
    when 'police' then 'Police'
    when 'shutdown' then 'Shut down'
    when 'line' then 'Line / wait'
    when 'capacity' then 'At capacity'
    else 'Update'
  end;
  what := label || case when coalesce(new.detail, '') <> '' then ': ' || new.detail else '' end;

  insert into public.notifications (user_id, kind, title, body, data)
  select p.id, 'report', pname, what,
         jsonb_build_object('place_id', new.place_id, 'report_id', new.id, 'report_kind', new.kind)
    from public.profiles p
    left join public.notification_prefs np on np.user_id = p.id
   where p.move = new.place_id::text
     and p.move_session in (
       to_char((now() at time zone 'utc')::date, 'YYYY-MM-DD'),
       to_char((now() at time zone 'utc')::date - 1, 'YYYY-MM-DD')
     )
     and p.id <> new.reporter_id
     and coalesce(np.report_on, true);
  return new;
end;
$$;

drop trigger if exists notify_report on public.place_reports;
create trigger notify_report after insert on public.place_reports
  for each row execute procedure public.notify_report();

-- ======================== phase8.sql ========================
-- ============================================================
-- PHASE 8 — @mentions in the live chat.
-- Typing @name in the live chat notifies that person (in the app and as
-- an iPhone push, through the same notifications table as phase 7).
-- Safe to re-run. Needs phase 7 first.
-- ============================================================

alter table public.notification_prefs
  add column if not exists mention_on boolean not null default true;

-- Same as phase 7's push_notify, plus the 'mention' kind.
create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           when 'mention' then mention_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, coalesce(d, '{}'::jsonb));
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public.notify_chat_mentions()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  author uuid := coalesce(new.sender_id, auth.uid());
  title text;
  h text;
  target uuid;
  sent integer := 0;
begin
  if new.text is null or position('@' in new.text) = 0 then
    return new;
  end if;

  if new.anon or new.sender_id is null then
    title := 'Someone mentioned you in live chat';
  else
    title := '@' || public.notif_handle(new.sender_id) || ' mentioned you';
  end if;

  for h in
    select distinct lower(m[1])
      from regexp_matches(new.text, '(?<![A-Za-z0-9_])@([A-Za-z0-9_]{2,30})', 'g') as m
  loop
    exit when sent >= 5;
    select id into target from public.profiles where lower(handle) = h;
    if target is not null and target is distinct from author then
      perform public.push_notify(
        target, 'mention', title, left(new.text, 120),
        jsonb_build_object('chat', true, 'message_id', new.id)
      );
      sent := sent + 1;
    end if;
    target := null;
  end loop;

  return new;
end;
$$;

revoke all on function public.notify_chat_mentions() from public, anon, authenticated;

drop trigger if exists notify_chat_mentions on public.chat_messages;
create trigger notify_chat_mentions after insert on public.chat_messages
  for each row execute procedure public.notify_chat_mentions();

-- ======================== phase9.sql ========================
-- ============================================================
-- PHASE 9 — Star ratings for places (0.5 to 5 stars, half stars OK).
-- One rating per person per place, and you can only rate a given place
-- once every 30 days (removing your rating doesn't reset that clock).
-- Safe to re-run.
-- ============================================================

create table if not exists public.place_ratings (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  stars numeric(2,1) not null check (stars >= 0.5 and stars <= 5 and (stars * 2) = floor(stars * 2)),
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

-- Remembers WHEN you last rated each place, so removing a rating can't be
-- used to dodge the once-a-month limit. Only the rating functions touch it.
create table if not exists public.place_rating_log (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  rated_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

alter table public.place_ratings enable row level security;
alter table public.place_rating_log enable row level security;

drop policy if exists "See place ratings" on public.place_ratings;
create policy "See place ratings"
  on public.place_ratings for select to authenticated using (true);

drop policy if exists "See own rating log" on public.place_rating_log;
create policy "See own rating log"
  on public.place_rating_log for select to authenticated using (auth.uid() = user_id);

-- No insert/update/delete policies on purpose: everything goes through
-- rate_place / remove_my_rating below.

-- Rate (or re-rate) a place. Returns null when it worked, otherwise a
-- short message to show the person.
create or replace function public.rate_place(p_place uuid, p_stars numeric)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  last_at timestamptz;
begin
  if uid is null then return 'Sign in to rate places.'; end if;
  if public.is_banned() then return 'Your account can''t rate places.'; end if;
  if p_stars is null or p_stars < 0.5 or p_stars > 5 or (p_stars * 2) <> floor(p_stars * 2) then
    return 'Pick between half a star and 5 stars.';
  end if;
  if not exists (select 1 from public.places where id = p_place) then
    return 'That place isn''t around anymore.';
  end if;

  select rated_at into last_at from public.place_rating_log
   where place_id = p_place and user_id = uid;
  if last_at is not null and last_at > now() - interval '30 days' then
    return 'You can rate this place again on ' || to_char((last_at + interval '30 days') at time zone 'UTC', 'Mon FMDD') || '.';
  end if;

  insert into public.place_rating_log (place_id, user_id, rated_at)
  values (p_place, uid, now())
  on conflict (place_id, user_id) do update set rated_at = excluded.rated_at;

  insert into public.place_ratings (place_id, user_id, stars, created_at)
  values (p_place, uid, p_stars, now())
  on conflict (place_id, user_id) do update set stars = excluded.stars, created_at = excluded.created_at;

  return null;
end;
$$;

-- Take your rating back any time (the monthly wait still applies).
create or replace function public.remove_my_rating(p_place uuid)
returns void
language sql
security definer set search_path = public
as $$
  delete from public.place_ratings where place_id = p_place and user_id = auth.uid();
$$;

-- One call for the whole app: average + count per place, plus your own
-- rating and when you're next allowed to rate it.
create or replace function public.place_rating_stats()
returns table (place_id uuid, avg_stars numeric, rating_count bigint, my_stars numeric, my_next_at timestamptz)
language sql
stable
security definer set search_path = public
as $$
  select p.place_id,
         round(avg(p.stars), 2) as avg_stars,
         count(*) as rating_count,
         max(p.stars) filter (where p.user_id = auth.uid()) as my_stars,
         (select l.rated_at + interval '30 days' from public.place_rating_log l
           where l.place_id = p.place_id and l.user_id = auth.uid()) as my_next_at
    from public.place_ratings p
   group by p.place_id
  union all
  -- places you rated before and then removed (no ratings left on them)
  select l.place_id, null, 0, null, l.rated_at + interval '30 days'
    from public.place_rating_log l
   where l.user_id = auth.uid()
     and not exists (select 1 from public.place_ratings r where r.place_id = l.place_id);
$$;

grant execute on function public.rate_place(uuid, numeric) to authenticated;
grant execute on function public.remove_my_rating(uuid) to authenticated;
grant execute on function public.place_rating_stats() to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'place_ratings'
  ) then
    alter publication supabase_realtime add table public.place_ratings;
  end if;
end $$;

-- ======================== phase10.sql ========================
-- ============================================================
-- PHASE 10 — Admin approvals: anyone can suggest a picture for a place (a
-- FUNKY Admin approves it before it shows up for everyone), and anyone can
-- report a profile (the admin reviews the reports).
-- Safe to re-run. Needs phases 2, 3 and 7 first.
-- ============================================================

-- The approved picture shown on the map, in lists and on the place page.
alter table public.places add column if not exists photo_url text;

create table if not exists public.place_photo_suggestions (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  url text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);

-- One waiting picture per person per place.
create unique index if not exists place_photo_one_pending
  on public.place_photo_suggestions (place_id, user_id) where status = 'pending';

alter table public.place_photo_suggestions enable row level security;

-- You see your own suggestions; the admin sees all. No insert/update/delete
-- policies: everything goes through the functions below.
drop policy if exists "See own or admin photo suggestions" on public.place_photo_suggestions;
create policy "See own or admin photo suggestions"
  on public.place_photo_suggestions for select to authenticated
  using (auth.uid() = user_id or public.is_admin());

-- Suggest a picture (its file is already uploaded to the place_covers
-- bucket under your own folder). An admin's picture goes live right away;
-- anyone else's waits for approval. Returns 'approved', 'pending', or an
-- error message starting with "!".
create or replace function public.suggest_place_photo(p_place uuid, p_url text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return '!Sign in to add a picture.'; end if;
  if public.is_banned() then return '!Your account can''t add pictures.'; end if;
  if p_url is null or length(p_url) < 10 or length(p_url) > 600 then return '!Bad picture.'; end if;
  if not exists (select 1 from public.places where id = p_place) then
    return '!That place isn''t around anymore.';
  end if;

  if public.is_admin() then
    update public.places set photo_url = p_url where id = p_place;
    return 'approved';
  end if;

  if (select count(*) from public.place_photo_suggestions
       where user_id = uid and created_at > now() - interval '1 day') >= 5 then
    return '!That''s enough pictures for today — try again tomorrow.';
  end if;

  -- A newer suggestion replaces your earlier waiting one for this place.
  delete from public.place_photo_suggestions
   where place_id = p_place and user_id = uid and status = 'pending';
  insert into public.place_photo_suggestions (place_id, user_id, url) values (p_place, uid, p_url);
  return 'pending';
end;
$$;

-- Admin: approve or reject a waiting picture. The person who suggested it
-- gets a notification either way.
create or replace function public.review_place_photo(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  s public.place_photo_suggestions;
  pname text;
begin
  if not public.is_admin() then return; end if;
  select * into s from public.place_photo_suggestions where id = p_id and status = 'pending';
  if not found then return; end if;
  select name into pname from public.places where id = s.place_id;

  if p_approve then
    update public.places set photo_url = s.url where id = s.place_id;
    update public.place_photo_suggestions set status = 'approved' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Your picture was approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' is live.',
      jsonb_build_object('place_id', s.place_id));
  else
    update public.place_photo_suggestions set status = 'rejected' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Picture not approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' wasn''t approved.',
      jsonb_build_object('place_id', s.place_id));
  end if;
end;
$$;

-- Admin: take the current picture off a place.
create or replace function public.clear_place_photo(p_place uuid)
returns void
language sql
security definer set search_path = public
as $$
  update public.places set photo_url = null where id = p_place and public.is_admin();
$$;

grant execute on function public.suggest_place_photo(uuid, text) to authenticated;
grant execute on function public.review_place_photo(uuid, boolean) to authenticated;
grant execute on function public.clear_place_photo(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'place_photo_suggestions'
  ) then
    alter publication supabase_realtime add table public.place_photo_suggestions;
  end if;
end $$;

-- ------------------------------------------------------------
-- Profile reports
-- ------------------------------------------------------------

create table if not exists public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reported_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null check (char_length(reason) between 2 and 80),
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_at timestamptz not null default now()
);

create unique index if not exists profile_report_one_open
  on public.profile_reports (reporter_id, reported_id) where status = 'open';

alter table public.profile_reports enable row level security;

-- Only the admin reads reports. Filing one goes through report_profile.
drop policy if exists "Admin sees profile reports" on public.profile_reports;
create policy "Admin sees profile reports"
  on public.profile_reports for select to authenticated
  using (public.is_admin());

-- File a report. Returns null when it worked, otherwise a message to show.
create or replace function public.report_profile(p_user uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
begin
  if uid is null then return 'Sign in to report someone.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if p_user is null or p_user = uid then return 'You can''t report yourself.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return 'That profile isn''t around anymore.'; end if;
  if exists (select 1 from public.profile_reports
              where reporter_id = uid and reported_id = p_user and status = 'open') then
    return 'You already reported this person — the team will take a look.';
  end if;
  if (select count(*) from public.profile_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 10 then
    return 'That''s a lot of reports for one day — try again tomorrow.';
  end if;
  insert into public.profile_reports (reporter_id, reported_id, reason) values (uid, p_user, r);
  return null;
end;
$$;

-- Admin: mark a report as dealt with.
create or replace function public.resolve_profile_report(p_id uuid)
returns void
language sql
security definer set search_path = public
as $$
  update public.profile_reports set status = 'resolved' where id = p_id and public.is_admin();
$$;

grant execute on function public.report_profile(uuid, text) to authenticated;
grant execute on function public.resolve_profile_report(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profile_reports'
  ) then
    alter publication supabase_realtime add table public.profile_reports;
  end if;
end $$;

-- ======================== phase11.sql ========================
-- ============================================================
-- PHASE 11 — Group chats (named, several friends), with photos/videos.
-- Safe to re-run. Needs phases 2 and 7 first (and 8 for @mentions).
-- ============================================================

create table if not exists public.group_chats (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.group_chats (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index if not exists group_members_user on public.group_members (user_id);

create table if not exists public.group_messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.group_chats (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  text text not null default '' check (char_length(text) <= 240),
  media_path text,
  media_type text check (media_type in ('image', 'video')),
  created_at timestamptz not null default now(),
  check (char_length(text) > 0 or media_path is not null)
);

create index if not exists group_messages_by_group on public.group_messages (group_id, created_at);

-- Are you in this group? (security definer so the policies below don't
-- recurse into group_members' own policy.)
create or replace function public.is_group_member(gid uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid());
$$;

alter table public.group_chats enable row level security;
alter table public.group_members enable row level security;
alter table public.group_messages enable row level security;

drop policy if exists "See your groups" on public.group_chats;
create policy "See your groups"
  on public.group_chats for select to authenticated
  using (public.is_group_member(id));

drop policy if exists "See members of your groups" on public.group_members;
create policy "See members of your groups"
  on public.group_members for select to authenticated
  using (public.is_group_member(group_id));

drop policy if exists "Read your group messages" on public.group_messages;
create policy "Read your group messages"
  on public.group_messages for select to authenticated
  using (public.is_group_member(group_id));

drop policy if exists "Send to your groups" on public.group_messages;
create policy "Send to your groups"
  on public.group_messages for insert to authenticated
  with check (auth.uid() = sender_id and public.is_group_member(group_id) and not public.is_banned());

drop trigger if exists rate_limit_group_messages on public.group_messages;
create trigger rate_limit_group_messages before insert on public.group_messages
  for each row execute procedure public.rate_limit('sender_id', '60', '30');

-- Everything else (creating, renaming, adding, leaving) goes through the
-- functions below.

create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.friendships f
     where f.status = 'accepted'
       and ((f.requester_id = a and f.addressee_id = b) or (f.requester_id = b and f.addressee_id = a))
  );
$$;

revoke all on function public.are_friends(uuid, uuid) from public, anon, authenticated;

-- Same as phase 8's push_notify, plus the 'group' kind (follows the DM
-- switch in Settings).
create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'group' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           when 'mention' then mention_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, d);
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

-- Make a group. p_members are the friends to add (you're added too).
create or replace function public.create_group(p_name text, p_members uuid[])
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  nm text := left(btrim(coalesce(p_name, '')), 40);
  m uuid;
  gid uuid;
  mem uuid[];
begin
  if uid is null then raise exception 'Sign in to start a group.'; end if;
  if public.is_banned() then raise exception 'Your account can''t start groups.'; end if;
  if char_length(nm) < 1 then raise exception 'Give the group a name.'; end if;
  select coalesce(array_agg(distinct x), '{}') into mem
    from unnest(coalesce(p_members, '{}')) as x where x is not null and x <> uid;
  if coalesce(array_length(mem, 1), 0) < 1 then raise exception 'Pick at least one friend.'; end if;
  if array_length(mem, 1) > 24 then raise exception 'A group can have up to 25 people.'; end if;
  if (select count(*) from public.group_chats where created_by = uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That''s a lot of new groups for one day — try again tomorrow.';
  end if;
  foreach m in array mem loop
    if not public.are_friends(uid, m) then
      raise exception 'You can only add friends to a group.';
    end if;
  end loop;

  insert into public.group_chats (name, created_by) values (nm, uid) returning id into gid;
  insert into public.group_members (group_id, user_id, added_by) values (gid, uid, uid);
  foreach m in array mem loop
    insert into public.group_members (group_id, user_id, added_by) values (gid, m, uid);
    perform public.push_notify(m, 'group', nm, '@' || public.notif_handle(uid) || ' added you to the group',
      jsonb_build_object('group_id', gid));
  end loop;
  return gid;
end;
$$;

create or replace function public.rename_group(p_group uuid, p_name text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  nm text := left(btrim(coalesce(p_name, '')), 40);
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group.'; end if;
  if char_length(nm) < 1 then raise exception 'Give the group a name.'; end if;
  update public.group_chats set name = nm where id = p_group;
end;
$$;

create or replace function public.add_group_members(p_group uuid, p_members uuid[])
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  m uuid;
  nm text;
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group.'; end if;
  if public.is_banned() then raise exception 'Your account can''t add people.'; end if;
  select name into nm from public.group_chats where id = p_group;
  foreach m in array coalesce(p_members, '{}') loop
    if m is null or m = uid then continue; end if;
    if exists (select 1 from public.group_members where group_id = p_group and user_id = m) then continue; end if;
    if not public.are_friends(uid, m) then raise exception 'You can only add friends to a group.'; end if;
    if (select count(*) from public.group_members where group_id = p_group) >= 25 then
      raise exception 'A group can have up to 25 people.';
    end if;
    insert into public.group_members (group_id, user_id, added_by) values (p_group, m, uid);
    perform public.push_notify(m, 'group', nm, '@' || public.notif_handle(uid) || ' added you to the group',
      jsonb_build_object('group_id', p_group));
  end loop;
end;
$$;

create or replace function public.leave_group(p_group uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  delete from public.group_members where group_id = p_group and user_id = auth.uid();
  if not exists (select 1 from public.group_members where group_id = p_group) then
    delete from public.group_chats where id = p_group;
  end if;
end;
$$;

grant execute on function public.create_group(text, uuid[]) to authenticated;
grant execute on function public.rename_group(uuid, text) to authenticated;
grant execute on function public.add_group_members(uuid, uuid[]) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;

-- Tell the other members about a new message (one tidy notification per
-- group: a newer unread one replaces the older).
create or replace function public.notify_group_message()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  nm text;
  who text;
  preview text;
  m record;
begin
  select name into nm from public.group_chats where id = new.group_id;
  who := public.notif_handle(new.sender_id);
  if new.media_path is not null and char_length(new.text) = 0 then
    preview := '@' || who || ' sent a ' || (case when new.media_type = 'video' then 'video' else 'photo' end);
  else
    preview := '@' || who || ': ' || left(new.text, 100);
  end if;
  for m in select user_id from public.group_members where group_id = new.group_id and user_id <> new.sender_id loop
    delete from public.notifications
     where user_id = m.user_id and kind = 'group' and read_at is null and data ->> 'group_id' = new.group_id::text;
    perform public.push_notify(m.user_id, 'group', coalesce(nm, 'Group chat'), preview,
      jsonb_build_object('group_id', new.group_id, 'message_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists notify_group_message on public.group_messages;
create trigger notify_group_message after insert on public.group_messages
  for each row execute procedure public.notify_group_message();

-- Group photos/videos: a private bucket (25 MB per file); files live under
-- "<group-id>/..." and only members can upload or read them.
insert into storage.buckets (id, name, public, file_size_limit)
values ('group_media', 'group_media', false, 26214400)
on conflict (id) do nothing;

create or replace function public.group_media_allowed(object_name text)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select case
           when (storage.foldername(object_name))[1] ~ '^[0-9a-fA-F-]{36}$'
             then public.is_group_member(((storage.foldername(object_name))[1])::uuid)
           else false
         end;
$$;

drop policy if exists "Upload to your groups" on storage.objects;
create policy "Upload to your groups"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'group_media' and public.group_media_allowed(name));

drop policy if exists "Read your groups' media" on storage.objects;
create policy "Read your groups' media"
  on storage.objects for select to authenticated
  using (bucket_id = 'group_media' and public.group_media_allowed(name));

do $$
declare
  t text;
begin
  foreach t in array array['group_chats', 'group_members', 'group_messages']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ======================== phase12.sql ========================
-- ============================================================
-- PHASE 12 — Your own "near me" distance (1–50 miles) and group photos.
-- Safe to re-run. Needs phases 7 and 11 first.
-- ============================================================

-- ---- Per-person radius, used for "new verified place near you" alerts ----

alter table public.user_locations
  add column if not exists radius_miles integer;

alter table public.user_locations
  drop constraint if exists user_locations_radius_miles_check;
alter table public.user_locations
  add constraint user_locations_radius_miles_check
  check (radius_miles is null or radius_miles between 1 and 50);

create or replace function public.notify_place_verified(pid uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pl public.places%rowtype;
begin
  select * into pl from public.places where id = pid;
  if not found then return; end if;

  insert into public.notifications (user_id, kind, title, body, data)
  select ul.user_id, 'place', 'New verified place near you',
         pl.name || ' is now verified on FUNKY',
         jsonb_build_object('place_id', pl.id)
    from public.user_locations ul
    left join public.notification_prefs np on np.user_id = ul.user_id
   cross join lateral (select coalesce(ul.radius_miles, 25)::double precision as r) rad
   where ul.user_id is distinct from pl.by_uid
     and coalesce(np.place_on, true)
     -- cheap box first (a degree of latitude is about 69 miles; longitude
     -- shrinks with latitude), then the exact great-circle distance.
     and ul.lat between pl.lat - rad.r / 69.0 and pl.lat + rad.r / 69.0
     and ul.lng between pl.lng - rad.r / (69.172 * greatest(0.01, cos(radians(pl.lat))))
                    and pl.lng + rad.r / (69.172 * greatest(0.01, cos(radians(pl.lat))))
     and 3958.8 * 2 * asin(least(1, sqrt(
           power(sin(radians(ul.lat - pl.lat) / 2), 2) +
           cos(radians(pl.lat)) * cos(radians(ul.lat)) *
           power(sin(radians(ul.lng - pl.lng) / 2), 2)
         ))) <= rad.r
     and not exists (
       select 1 from public.notifications n
        where n.user_id = ul.user_id
          and n.kind = 'place'
          and n.data ->> 'place_id' = pl.id::text
     );
end;
$$;

revoke all on function public.notify_place_verified(uuid) from public, anon, authenticated;

-- ---- A picture for a group chat -------------------------------------

alter table public.group_chats
  add column if not exists photo_url text;

create or replace function public.set_group_photo(p_group uuid, p_url text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  u text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group.'; end if;
  -- Only a picture this app uploaded (the public place_covers storage bucket).
  if u is not null and (char_length(u) > 600
      or u !~* '^https://[a-z0-9.-]+/storage/v1/object/public/place_covers/') then
    raise exception 'That picture link isn''t valid.';
  end if;
  update public.group_chats set photo_url = u where id = p_group;
end;
$$;

grant execute on function public.set_group_photo(uuid, text) to authenticated;

-- ======================== phase13.sql ========================
-- ============================================================
-- PHASE 13 — Video calls between friends (DMs).
-- Safe to re-run. Needs phases 7 and 11 first (push_notify, are_friends).
-- The live video itself runs through LiveKit; this just tracks who is
-- calling whom and whether it was answered. See supabase/VIDEO_CALLS_SETUP.md.
-- ============================================================

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles (id) on delete cascade,
  callee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'ringing'
    check (status in ('ringing', 'accepted', 'declined', 'cancelled', 'missed', 'ended')),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz,
  check (caller_id <> callee_id)
);

create index if not exists calls_callee_idx on public.calls (callee_id, created_at desc);
create index if not exists calls_caller_idx on public.calls (caller_id, created_at desc);

alter table public.calls enable row level security;

-- You can see calls you're in. Nobody writes to this table directly —
-- only the functions below do.
drop policy if exists "See your own calls" on public.calls;
create policy "See your own calls"
  on public.calls for select to authenticated
  using (auth.uid() = caller_id or auth.uid() = callee_id);

-- ---- 'call' notifications follow the "Direct messages & groups" switch ----

create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'group' then dm_on
           when 'call' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           when 'mention' then mention_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, d);
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

-- ---- Start a call (friends only) ------------------------------------

create or replace function public.start_call(p_callee uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  who text;
begin
  if uid is null then raise exception 'Log in to make a video call.'; end if;
  if p_callee is null or p_callee = uid then raise exception 'Pick someone to call.'; end if;
  if public.is_banned() then raise exception 'You can''t make calls right now.'; end if;
  if not public.are_friends(uid, p_callee) then
    raise exception 'You can only video chat with friends.';
  end if;

  -- Housekeeping: rings that nobody answered are missed; calls left open
  -- for hours (app killed mid-call) are over.
  update public.calls set status = 'missed', ended_at = now()
   where status = 'ringing' and created_at < now() - interval '60 seconds';
  update public.calls set status = 'ended', ended_at = now()
   where status = 'accepted' and ended_at is null and answered_at < now() - interval '3 hours';

  -- Starting a new call drops any ring of yours that's still going.
  update public.calls set status = 'cancelled', ended_at = now()
   where caller_id = uid and status = 'ringing';

  if exists (
    select 1 from public.calls
     where status in ('ringing', 'accepted') and ended_at is null
       and (caller_id = p_callee or callee_id = p_callee)
  ) then
    raise exception 'They''re busy on another call right now.';
  end if;
  if exists (
    select 1 from public.calls
     where status = 'accepted' and ended_at is null
       and (caller_id = uid or callee_id = uid)
  ) then
    raise exception 'You''re already on a call.';
  end if;

  if (select count(*) from public.calls where caller_id = uid and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Slow down — too many calls in a row.';
  end if;

  insert into public.calls (caller_id, callee_id) values (uid, p_callee) returning id into cid;

  select handle into who from public.profiles where id = uid;
  perform public.push_notify(
    p_callee, 'call',
    '📹 @' || coalesce(who, 'someone') || ' is calling',
    'Tap to answer the video call',
    jsonb_build_object('call_id', cid, 'from', uid)
  );

  return cid;
end;
$$;

-- ---- Answer / decline / cancel / hang up ------------------------------

create or replace function public.respond_call(p_call uuid, p_action text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  c public.calls%rowtype;
  who text;
begin
  if uid is null then raise exception 'Log in first.'; end if;
  select * into c from public.calls where id = p_call for update;
  if not found or (uid <> c.caller_id and uid <> c.callee_id) then
    raise exception 'That call isn''t available.';
  end if;

  if p_action = 'accept' then
    if uid <> c.callee_id then raise exception 'Only the person being called can answer.'; end if;
    if c.status <> 'ringing' or c.created_at < now() - interval '75 seconds' then
      if c.status = 'ringing' then
        update public.calls set status = 'missed', ended_at = now() where id = c.id;
      end if;
      raise exception 'That call already ended.';
    end if;
    update public.calls set status = 'accepted', answered_at = now() where id = c.id;
    return 'accepted';

  elsif p_action = 'decline' then
    if uid <> c.callee_id then raise exception 'Only the person being called can decline.'; end if;
    if c.status = 'ringing' then
      update public.calls set status = 'declined', ended_at = now() where id = c.id;
    end if;
    return 'declined';

  elsif p_action = 'cancel' then
    if uid <> c.caller_id then raise exception 'Only the caller can cancel.'; end if;
    if c.status = 'ringing' then
      update public.calls set status = 'cancelled', ended_at = now() where id = c.id;
      select handle into who from public.profiles where id = uid;
      perform public.push_notify(
        c.callee_id, 'call',
        'Missed video call',
        '@' || coalesce(who, 'someone') || ' tried to video chat with you',
        jsonb_build_object('from', uid)
      );
    end if;
    return 'cancelled';

  elsif p_action = 'end' then
    if c.status = 'accepted' then
      update public.calls set status = 'ended', ended_at = now() where id = c.id;
    elsif c.status = 'ringing' and uid = c.caller_id then
      update public.calls set status = 'cancelled', ended_at = now() where id = c.id;
    end if;
    return 'ended';
  end if;

  raise exception 'Unknown call action.';
end;
$$;

revoke all on function public.start_call(uuid) from public, anon;
revoke all on function public.respond_call(uuid, text) from public, anon;
grant execute on function public.start_call(uuid) to authenticated;
grant execute on function public.respond_call(uuid, text) to authenticated;

-- Live updates of the calls table (an incoming ring, a hang-up).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'calls'
  ) then
    alter publication supabase_realtime add table public.calls;
  end if;
end $$;

-- ======================== phase14.sql ========================
-- ============================================================
-- PHASE 14 — Group video calls (inside group chats).
-- Safe to re-run. Needs phases 11 and 13 first.
-- The live video runs through LiveKit (see VIDEO_CALLS_SETUP.md); this just
-- tracks which group has a call going so members can see it and join.
-- ============================================================

create table if not exists public.group_calls (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.group_chats (id) on delete cascade,
  started_by uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'ended')),
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  ended_at timestamptz
);

create index if not exists group_calls_group_idx on public.group_calls (group_id, created_at desc);

alter table public.group_calls enable row level security;

drop policy if exists "See your groups' calls" on public.group_calls;
create policy "See your groups' calls"
  on public.group_calls for select to authenticated
  using (public.is_group_member(group_id));

-- 'group_call' notifications follow the "Direct messages & groups" switch.
create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'group' then dm_on
           when 'call' then dm_on
           when 'group_call' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           when 'mention' then mention_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, d);
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

-- Start a call in a group — or join the one already going. Returns the call id.
create or replace function public.start_group_call(p_group uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  existing uuid;
  cid uuid;
  who text;
  gname text;
  m record;
begin
  if uid is null then raise exception 'Log in to make a video call.'; end if;
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group.'; end if;
  if public.is_banned() then raise exception 'You can''t make calls right now.'; end if;

  -- Calls nobody has pinged for a minute and a half are over.
  update public.group_calls set status = 'ended', ended_at = now()
   where group_id = p_group and status = 'active' and last_active_at < now() - interval '90 seconds';

  select id into existing from public.group_calls
   where group_id = p_group and status = 'active'
   order by created_at desc limit 1;
  if existing is not null then
    update public.group_calls set last_active_at = now() where id = existing;
    return existing;
  end if;

  if (select count(*) from public.group_calls where started_by = uid and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Slow down — too many calls in a row.';
  end if;

  insert into public.group_calls (group_id, started_by) values (p_group, uid) returning id into cid;

  select handle into who from public.profiles where id = uid;
  select name into gname from public.group_chats where id = p_group;
  for m in select user_id from public.group_members where group_id = p_group and user_id <> uid loop
    perform public.push_notify(
      m.user_id, 'group_call',
      '📹 @' || coalesce(who, 'someone') || ' started a video call',
      'In ' || coalesce(gname, 'your group') || ' — tap to join',
      jsonb_build_object('group_id', p_group, 'group_call_id', cid, 'from', uid)
    );
  end loop;

  return cid;
end;
$$;

-- Everyone in the call pings this every ~25 seconds so the group knows it's live.
create or replace function public.ping_group_call(p_call uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  gid uuid;
begin
  select group_id into gid from public.group_calls where id = p_call;
  if gid is null or not public.is_group_member(gid) then return; end if;
  update public.group_calls set last_active_at = now() where id = p_call and status = 'active';
end;
$$;

-- The last person out ends it.
create or replace function public.end_group_call(p_call uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  gid uuid;
begin
  select group_id into gid from public.group_calls where id = p_call;
  if gid is null or not public.is_group_member(gid) then return; end if;
  update public.group_calls set status = 'ended', ended_at = now() where id = p_call and status = 'active';
end;
$$;

-- Which of your groups have a call going right now (age measured on the
-- server, so a wrong phone clock can't hide it).
create or replace function public.active_group_calls()
returns table (id uuid, group_id uuid, started_by uuid, age_seconds integer)
language sql
security definer set search_path = public
as $$
  select gc.id, gc.group_id, gc.started_by,
         extract(epoch from (now() - gc.last_active_at))::integer
    from public.group_calls gc
   where gc.status = 'active'
     and gc.last_active_at > now() - interval '90 seconds'
     and public.is_group_member(gc.group_id);
$$;

revoke all on function public.start_group_call(uuid) from public, anon;
revoke all on function public.ping_group_call(uuid) from public, anon;
revoke all on function public.end_group_call(uuid) from public, anon;
revoke all on function public.active_group_calls() from public, anon;
grant execute on function public.start_group_call(uuid) to authenticated;
grant execute on function public.ping_group_call(uuid) to authenticated;
grant execute on function public.end_group_call(uuid) to authenticated;
grant execute on function public.active_group_calls() to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_calls'
  ) then
    alter publication supabase_realtime add table public.group_calls;
  end if;
end $$;

select 'FUNKY backend ready' as status;
