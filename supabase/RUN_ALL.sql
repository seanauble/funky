-- FUNKY: everything in one go (phase 2 + 3 + 4 + 5 + 6). Paste ALL of this into the
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

select 'FUNKY backend ready' as status;
