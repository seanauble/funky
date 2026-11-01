-- FUNKY: everything in one go (phase 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17 + 18 + 19 + 20 + 21 + 22 + 23 + 24 + 25 + 26 + 27 + 28 + 29 + 30 + 31 + 32 + 33 + 34). Paste ALL of this into the
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
  check (radius_miles is null or radius_miles between 1 and 5000); -- 50 for everyone, 5,000 for admins (see phase 18)

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

-- ======================== phase15.sql ========================
-- ============================================================
-- Phase 15: guest mode.
--
-- People without an account browse with a Supabase *anonymous* session
-- (turn on: Supabase → Authentication → Sign In / Providers →
-- "Allow anonymous sign-ins"). They're "authenticated" as far as the
-- database is concerned, so Places, Live Chat, place reports/ratings and
-- viewing Stories just work for them. These extra RESTRICTIVE rules keep
-- guests from the account-only stuff: liking Stories, posting Stories,
-- reacting to chat, DMs, group messages and friend requests.
-- Safe to run more than once.
-- ============================================================

create or replace function public.is_guest()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

grant execute on function public.is_guest() to authenticated;

drop policy if exists "Guests can't like stories" on public.story_likes;
create policy "Guests can't like stories"
  on public.story_likes as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't post stories" on public.stories;
create policy "Guests can't post stories"
  on public.stories as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't react to chat" on public.chat_reactions;
create policy "Guests can't react to chat"
  on public.chat_reactions as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't change chat reactions" on public.chat_reactions;
create policy "Guests can't change chat reactions"
  on public.chat_reactions as restrictive for update to authenticated
  using (not public.is_guest());

drop policy if exists "Guests can't send DMs" on public.messages;
create policy "Guests can't send DMs"
  on public.messages as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't message groups" on public.group_messages;
create policy "Guests can't message groups"
  on public.group_messages as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't send friend requests" on public.friendships;
create policy "Guests can't send friend requests"
  on public.friendships as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't accept friend requests" on public.friendships;
create policy "Guests can't accept friend requests"
  on public.friendships as restrictive for update to authenticated
  using (not public.is_guest());

-- Old guest sessions pile up as anonymous users; clean out ones that have
-- been idle for 30 days (their chat messages and places go with them only
-- if the tables cascade — profiles do). Run by hand whenever you like:
--   select public.purge_old_guests();
create or replace function public.purge_old_guests()
returns integer
language plpgsql
security definer set search_path = public, auth
as $$
declare
  n integer;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  with del as (
    delete from auth.users
    where is_anonymous
      and coalesce(last_sign_in_at, created_at) < now() - interval '30 days'
    returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_old_guests() to authenticated;

-- ======================== phase16.sql ========================
-- ============================================================
-- Phase 16: only FUNKY Admin-verified places last past 24 hours.
-- Places confirmed by the crowd (15+ people) are still "verified" for the
-- night, but now clear out 24 hours after they were added like any other.
-- Safe to run more than once.
-- ============================================================

create or replace function public.purge_stale_places()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  with del as (
    delete from public.places p
    where p.admin_verified = false
      -- A place with a date (phase 33) stays until a day after it starts.
      -- Read through jsonb so this still works before that column exists.
      and greatest(p.created_at, coalesce((to_jsonb(p) ->> 'starts_at')::timestamptz, p.created_at)) < now() - interval '24 hours'
    returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_stale_places() to authenticated;

-- Clear out the ones that are already past their 24 hours.
select public.purge_stale_places() as stale_places_removed;

-- ======================== phase17.sql ========================
-- ============================================================
-- Phase 17: friend counts on profiles.
-- Friendships are private (you can only read your own rows), so a
-- profile's "Friends" number comes from this count-only function — it
-- never reveals WHO someone's friends are. Safe to run more than once.
-- ============================================================

create or replace function public.friend_count(p_user uuid)
returns integer
language sql
stable
security definer set search_path = public
as $$
  select count(*)::int
  from public.friendships f
  where f.status = 'accepted'
    and (f.requester_id = p_user or f.addressee_id = p_user)
$$;

grant execute on function public.friend_count(uuid) to authenticated;

-- ======================== phase18.sql ========================
-- ============================================================
-- Phase 18: admins can set their "near me" radius up to 5,000 miles.
-- Everyone else stays at 1–50 (anything bigger from a non-admin is
-- quietly capped at 50). Safe to run more than once.
-- ============================================================

alter table public.user_locations
  drop constraint if exists user_locations_radius_miles_check;
alter table public.user_locations
  add constraint user_locations_radius_miles_check
  check (radius_miles is null or radius_miles between 1 and 5000);

create or replace function public.cap_radius_miles()
returns trigger
language plpgsql
as $$
begin
  if new.radius_miles is not null and new.radius_miles > 50 and not public.is_admin() then
    new.radius_miles := 50;
  end if;
  return new;
end;
$$;

drop trigger if exists cap_radius_miles on public.user_locations;
create trigger cap_radius_miles
  before insert or update on public.user_locations
  for each row execute procedure public.cap_radius_miles();

-- ======================== phase19.sql ========================
-- ============================================================
-- Phase 19: importing bars & clubs (OpenStreetMap) for admin review.
--
-- The import-venues Edge Function fills venue_candidates with every bar,
-- pub and nightclub within 50 miles of Egg Harbor (free OpenStreetMap
-- data). In the app's Admin panel → New venues, the admin adds a photo,
-- fixes the name/address, approves, denies, or leaves a note. Approving
-- creates a FUNKY-verified place (which never expires) with that photo.
-- Safe to run more than once.
-- ============================================================

create table if not exists public.venue_candidates (
  id uuid primary key default gen_random_uuid(),
  google_place_id text not null unique, -- where it came from, e.g. 'osm:node/123'
  name text not null,
  kind text not null default 'bar' check (kind in ('bar', 'club')),
  address text not null default '',
  lat double precision not null,
  lng double precision not null,
  distance_miles double precision,
  -- [{ "name": "places/…/photos/…", "credit": "Jane D." }, …]
  photos jsonb not null default '[]'::jsonb,
  photo_index integer not null default 0,
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'changes')),
  admin_note text,
  place_id uuid references public.places (id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create index if not exists venue_candidates_status on public.venue_candidates (status);

alter table public.venue_candidates enable row level security;

drop policy if exists "Admins see venue candidates" on public.venue_candidates;
create policy "Admins see venue candidates"
  on public.venue_candidates for select to authenticated
  using (public.is_admin());
-- No insert/update/delete policies: rows come in from the import function
-- (service role) and change only through review_venue() below.

-- A photo the admin added for this venue (public URL in place_covers).
alter table public.venue_candidates add column if not exists custom_photo_url text;

-- Who took the place's picture, when it needs a credit.
alter table public.places add column if not exists photo_credit text;

-- Approving lots of imported venues at once shouldn't send everyone a
-- "New verified place near you" alert for each one.
create or replace function public.notify_place_insert()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.admin_verified and coalesce(current_setting('funky.quiet_place_insert', true), '') <> 'on' then
    perform public.notify_place_verified(new.id);
  end if;
  return new;
end;
$$;

-- decision: 'approve' | 'deny' | 'changes' | 'pending'
-- Optional edits ride along: a new name, address, kind ('bar'/'club'),
-- which photo to use, and a note.
drop function if exists public.review_venue(uuid, text, text, text, text, integer);
create or replace function public.review_venue(
  p_id uuid,
  p_decision text,
  p_note text default null,
  p_name text default null,
  p_kind text default null,
  p_photo_index integer default null,
  p_address text default null
)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  c public.venue_candidates%rowtype;
  new_place uuid;
  photo jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_decision not in ('approve', 'deny', 'changes', 'pending') then raise exception 'Unknown decision.'; end if;

  update public.venue_candidates set
    name = coalesce(nullif(btrim(p_name), ''), name),
    address = coalesce(p_address, address),
    kind = case when p_kind in ('bar', 'club') then p_kind else kind end,
    photo_index = case
      when p_photo_index is not null and p_photo_index >= 0 and p_photo_index < jsonb_array_length(photos) then p_photo_index
      else photo_index end,
    admin_note = case when p_note is not null then nullif(btrim(p_note), '') else admin_note end
  where id = p_id
  returning * into c;
  if not found then raise exception 'That venue is gone.'; end if;

  if p_decision = 'approve' then
    -- The admin's own photo wins; otherwise the picked imported one.
    if c.custom_photo_url is not null then
      photo := jsonb_build_object('url', c.custom_photo_url);
    else
      photo := c.photos -> c.photo_index;
    end if;
    if c.place_id is null or not exists (select 1 from public.places where id = c.place_id) then
      perform set_config('funky.quiet_place_insert', 'on', true);
      insert into public.places (name, kind, lat, lng, address, by_uid, admin_verified, photo_url, photo_credit)
      values (
        left(c.name, 40), c.kind, c.lat, c.lng, left(c.address, 80), auth.uid(), true,
        case when photo is null then null when photo ? 'url' then photo ->> 'url' else 'gplace:' || (photo ->> 'name') end,
        photo ->> 'credit'
      )
      returning id into new_place;
      perform set_config('funky.quiet_place_insert', 'off', true);
    else
      new_place := c.place_id;
      update public.places set
        name = left(c.name, 40),
        kind = c.kind,
        admin_verified = true,
        photo_url = case when photo is null then photo_url when photo ? 'url' then photo ->> 'url' else 'gplace:' || (photo ->> 'name') end,
        photo_credit = case when photo is null then photo_credit else photo ->> 'credit' end
      where id = new_place;
    end if;
    update public.venue_candidates set status = 'approved', place_id = new_place, reviewed_at = now() where id = p_id;
    return new_place;
  end if;

  update public.venue_candidates set
    status = case p_decision when 'deny' then 'denied' when 'changes' then 'changes' else 'pending' end,
    reviewed_at = now()
  where id = p_id;
  return null;
end;
$$;

grant execute on function public.review_venue(uuid, text, text, text, text, integer, text) to authenticated;

-- The admin's photo for a venue (null removes it). If it's already live on
-- the map, the place's picture changes too.
create or replace function public.set_venue_photo(p_id uuid, p_url text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.venue_candidates set custom_photo_url = nullif(btrim(p_url), '')
  where id = p_id
  returning place_id into pid;
  if not found then raise exception 'That venue is gone.'; end if;
  if pid is not null and nullif(btrim(p_url), '') is not null then
    update public.places set photo_url = btrim(p_url), photo_credit = null where id = pid;
  end if;
end;
$$;

grant execute on function public.set_venue_photo(uuid, text) to authenticated;

-- ======================== phase20.sql ========================
-- ============================================================
-- Phase 20: admins can drag an imported venue's pin to the right spot.
-- (Moving a place that's already on the map uses the existing
-- "Admin can verify places" update rule.) Safe to run more than once.
-- ============================================================

create or replace function public.set_venue_location(p_id uuid, p_lat double precision, p_lng double precision)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'That spot isn''t on the map.';
  end if;
  update public.venue_candidates set lat = p_lat, lng = p_lng
  where id = p_id
  returning place_id into pid;
  if not found then raise exception 'That venue is gone.'; end if;
  if pid is not null then
    update public.places set lat = p_lat, lng = p_lng where id = pid;
  end if;
end;
$$;

grant execute on function public.set_venue_location(uuid, double precision, double precision) to authenticated;

-- ======================== phase21.sql ========================
-- ============================================================
-- Phase 21: the admin's phone imports bars & clubs itself.
-- The app downloads the list from OpenStreetMap directly (the shared
-- servers Supabase functions run on get turned away as "busy") and hands
-- it to this function, which adds anything new for review. Skips venues
-- already imported or already on the map under the same name nearby.
-- Safe to run more than once.
-- ============================================================

create or replace function public.import_venue_candidates(p_rows jsonb)
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  r jsonb;
  n integer := 0;
  v_lat double precision;
  v_lng double precision;
  v_name text;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'Expected a list.'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := left(btrim(coalesce(r ->> 'name', '')), 60);
    v_lat := (r ->> 'lat')::double precision;
    v_lng := (r ->> 'lng')::double precision;
    continue when v_name = '' or v_lat is null or v_lng is null or coalesce(r ->> 'source_id', '') = '';
    -- Already on the map under that name, within about 0.2 miles.
    continue when exists (
      select 1 from public.places p
      where lower(p.name) = lower(v_name)
        and abs(p.lat - v_lat) < 0.003
        and abs(p.lng - v_lng) < 0.004
    );
    insert into public.venue_candidates (google_place_id, name, kind, address, lat, lng, distance_miles, photos)
    values (
      r ->> 'source_id',
      v_name,
      case when r ->> 'kind' = 'club' then 'club' else 'bar' end,
      left(coalesce(r ->> 'address', ''), 120),
      v_lat,
      v_lng,
      nullif(r ->> 'distance_miles', '')::double precision,
      '[]'::jsonb
    )
    on conflict (google_place_id) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

grant execute on function public.import_venue_candidates(jsonb) to authenticated;

-- ======================== phase22.sql ========================
-- ============================================================
-- Phase 22: fill in an imported venue's street address.
-- OpenStreetMap often has the exact pin but no address; the app looks
-- the address up from the pin and saves it here. Safe to run more than once.
-- ============================================================

create or replace function public.set_venue_address(p_id uuid, p_address text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.venue_candidates set address = left(btrim(coalesce(p_address, '')), 120)
  where id = p_id
  returning place_id into pid;
  if pid is not null then
    update public.places set address = left(btrim(coalesce(p_address, '')), 80)
    where id = pid and address = '';
  end if;
end;
$$;

grant execute on function public.set_venue_address(uuid, text) to authenticated;

-- ======================== phase23.sql ========================
-- ============================================================
-- Phase 23: +1,000 Funky Points when your picture for a place is approved.
-- Paid once per person per place (a second approved picture of the same
-- spot doesn't pay again). The points arrive as bonus points, so the
-- person's app picks them up live. Safe to run more than once.
-- ============================================================

create or replace function public.review_place_photo(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  s public.place_photo_suggestions;
  pname text;
  first_for_place boolean;
begin
  if not public.is_admin() then return; end if;
  select * into s from public.place_photo_suggestions where id = p_id and status = 'pending';
  if not found then return; end if;
  select name into pname from public.places where id = s.place_id;

  if p_approve then
    first_for_place := not exists (
      select 1 from public.place_photo_suggestions
      where user_id = s.user_id and place_id = s.place_id and status = 'approved' and id <> s.id
    );
    update public.places set photo_url = s.url, photo_credit = null where id = s.place_id;
    update public.place_photo_suggestions set status = 'approved' where id = s.id;
    if first_for_place then
      update public.profiles set bonus_points = bonus_points + 1000 where id = s.user_id;
      perform public.push_notify(s.user_id, 'photo', 'Your picture was approved — +1,000 points!',
        'Your picture for ' || coalesce(pname, 'the place') || ' is live. 1,000 Funky Points added.',
        jsonb_build_object('place_id', s.place_id));
    else
      perform public.push_notify(s.user_id, 'photo', 'Your picture was approved',
        'Your picture for ' || coalesce(pname, 'the place') || ' is live.',
        jsonb_build_object('place_id', s.place_id));
    end if;
  else
    update public.place_photo_suggestions set status = 'rejected' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Picture not approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' wasn''t approved.',
      jsonb_build_object('place_id', s.place_id));
  end if;
end;
$$;

grant execute on function public.review_place_photo(uuid, boolean) to authenticated;

-- ======================== phase24.sql ========================
-- ============================================================
-- Phase 24: stories remember where they were posted, so an Area story
-- only shows to people within range of it (the app filters by your radius).
-- Safe to run more than once.
-- ============================================================

alter table public.stories add column if not exists lat double precision;
alter table public.stories add column if not exists lng double precision;

-- ======================== phase25.sql ========================
-- ============================================================
-- Phase 25: replying to a Story from the Story viewer ("swipe up")
-- sends a DM that remembers which Story it answered, so both people
-- see a small preview of it above the message in the chat.
-- Safe to run more than once.
-- ============================================================

alter table public.messages add column if not exists story_id uuid;
alter table public.messages add column if not exists story_text text;
alter table public.messages add column if not exists story_media_path text;
alter table public.messages add column if not exists story_is_video boolean not null default false;

-- Keep the snapshot small.
alter table public.messages drop constraint if exists messages_story_text_len;
alter table public.messages add constraint messages_story_text_len
  check (story_text is null or char_length(story_text) <= 200);

-- The two people in a story-reply DM can keep loading that Story's
-- picture for the preview, even after the 24 hours are up.
drop policy if exists "Read story media replied to in your DMs" on storage.objects;
create policy "Read story media replied to in your DMs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'stories'
    and exists (
      select 1 from public.messages m
      where m.story_media_path = name
        and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())
    )
  );

create index if not exists messages_story_media_path_idx
  on public.messages (story_media_path) where story_media_path is not null;

-- ======================== phase26.sql ========================
-- ============================================================
-- Phase 26:
--   1) Every Story gets a location, so "your radius reaches it" works for
--      everyone. A Story posted without one (an older app version, or GPS
--      wasn't ready yet) takes its venue's spot, or else the poster's last
--      known location. Stories from the last 2 days are back-filled.
--   2) Report a Story: the flag on a Story sends it to the FUNKY admins,
--      with a copy of the Story (even if it's anonymous or expires), to
--      dismiss or remove.
-- Safe to run more than once.
-- ============================================================

alter table public.stories add column if not exists lat double precision;
alter table public.stories add column if not exists lng double precision;

create or replace function public.fill_story_location()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  plat double precision;
  plng double precision;
begin
  if new.lat is not null and new.lng is not null then
    return new;
  end if;
  if new.place_id is not null and new.place_id <> 'main' then
    select p.lat, p.lng into plat, plng from public.places p where p.id::text = lower(new.place_id);
  end if;
  if plat is null then
    select ul.lat, ul.lng into plat, plng
      from public.user_locations ul
     where ul.user_id = new.uid
       and ul.updated_at > now() - interval '3 days';
  end if;
  if plat is not null and plng is not null then
    new.lat := plat;
    new.lng := plng;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_fill_location on public.stories;
create trigger stories_fill_location
  before insert on public.stories
  for each row execute function public.fill_story_location();

-- Back-fill recent Stories that were posted without a location.
update public.stories s
   set lat = p.lat, lng = p.lng
  from public.places p
 where s.lat is null
   and s.created_at > now() - interval '2 days'
   and s.place_id is not null
   and p.id::text = lower(s.place_id);

update public.stories s
   set lat = ul.lat, lng = ul.lng
  from public.user_locations ul
 where s.lat is null
   and s.created_at > now() - interval '2 days'
   and ul.user_id = s.uid;

-- ---- Story reports --------------------------------------------------

create table if not exists public.story_reports (
  id uuid primary key default gen_random_uuid(),
  story_id uuid references public.stories (id) on delete set null,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  poster_id uuid references auth.users (id) on delete cascade,
  reason text not null check (char_length(reason) between 2 and 80),
  -- A copy of the Story so it can still be reviewed after it expires or
  -- is deleted.
  story_text text,
  story_media_path text,
  story_is_video boolean not null default false,
  story_anon boolean not null default false,
  story_place_name text,
  story_created_at timestamptz,
  status text not null default 'open' check (status in ('open', 'resolved')),
  outcome text check (outcome is null or outcome in ('dismissed', 'removed')),
  created_at timestamptz not null default now()
);

create unique index if not exists story_report_one_open
  on public.story_reports (reporter_id, story_id) where status = 'open';
create index if not exists story_reports_open_idx
  on public.story_reports (created_at) where status = 'open';

alter table public.story_reports enable row level security;
grant select on public.story_reports to authenticated;

-- Only admins read reports. Filing one goes through report_story.
drop policy if exists "Admins see story reports" on public.story_reports;
create policy "Admins see story reports"
  on public.story_reports for select to authenticated
  using (public.is_admin());

-- Admins can open any Story picture/video (to review a reported one).
drop policy if exists "Admins read all story media" on storage.objects;
create policy "Admins read all story media"
  on storage.objects for select to authenticated
  using (bucket_id = 'stories' and public.is_admin());

-- File a report. Returns null when it worked, otherwise a message to show.
create or replace function public.report_story(p_story uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
  s public.stories%rowtype;
  rid uuid;
  who text;
  a record;
begin
  if uid is null then return 'Sign in to report a story.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  select * into s from public.stories where id = p_story;
  if not found then return 'That story isn''t up anymore.'; end if;
  if s.uid = uid then return 'That''s your own story.'; end if;
  if exists (select 1 from public.story_reports
              where reporter_id = uid and story_id = p_story and status = 'open') then
    return 'You already reported this story. The FUNKY team will take a look.';
  end if;
  if (select count(*) from public.story_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 15 then
    return 'That''s a lot of reports for one day. Try again tomorrow.';
  end if;

  insert into public.story_reports (
    story_id, reporter_id, poster_id, reason,
    story_text, story_media_path, story_is_video, story_anon, story_place_name, story_created_at)
  values (
    s.id, uid, s.uid, r,
    left(s.text, 300), s.media_path, coalesce(s.is_video, false), coalesce(s.anon, false), s.place_name, s.created_at)
  returning id into rid;

  -- Ping the admins on the first report for this Story.
  if (select count(*) from public.story_reports where story_id = s.id and status = 'open') = 1 then
    select handle into who from public.profiles where id = s.uid;
    for a in
      select p.id from public.profiles p
       where p.is_admin
          or p.id in (select u.id from auth.users u where lower(u.email) = 'seanauble@icloud.com')
    loop
      if a.id <> uid then
        perform public.push_notify(
          a.id, 'story_report', 'Story reported',
          (case when coalesce(s.anon, false) then 'An anonymous story' else '@' || coalesce(who, 'someone') || '''s story' end)
            || ' was reported: ' || r,
          jsonb_build_object('report_id', rid, 'story_id', s.id));
      end if;
    end loop;
  end if;
  return null;
end;
$$;

-- Admin: close a report (and every other open report on the same Story).
-- p_remove = true also deletes the Story and lets the poster know.
create or replace function public.resolve_story_report(p_id uuid, p_remove boolean default false)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  rep public.story_reports%rowtype;
begin
  if not public.is_admin() then return 'Admins only.'; end if;
  select * into rep from public.story_reports where id = p_id;
  if not found then return 'That report is gone.'; end if;

  update public.story_reports
     set status = 'resolved',
         outcome = case when p_remove then 'removed' else 'dismissed' end
   where status = 'open'
     and (id = p_id or (rep.story_id is not null and story_id = rep.story_id));

  if p_remove then
    if rep.story_id is not null then
      delete from public.stories where id = rep.story_id;
    end if;
    if rep.poster_id is not null then
      perform public.push_notify(
        rep.poster_id, 'moderation', 'Your story was removed',
        'One of your stories broke the FUNKY community rules (' || rep.reason || ') and was taken down.',
        '{}'::jsonb);
    end if;
  end if;
  return null;
end;
$$;

grant execute on function public.report_story(uuid, text) to authenticated;
grant execute on function public.resolve_story_report(uuid, boolean) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'story_reports'
  ) then
    alter publication supabase_realtime add table public.story_reports;
  end if;
end $$;

-- ======================== phase27.sql ========================
-- ============================================================
-- Phase 27: "You've been here." Every night you tap "I'm going" on a
-- place, or post a Story there, is remembered, so the app can put a
-- been-here badge next to places you've been. Only you can see your own.
-- Filled in automatically by the database (works for older app versions
-- too), plus a one-time back-fill from your past Stories.
-- Safe to run more than once.
-- ============================================================

create table if not exists public.place_visits (
  user_id uuid not null references auth.users (id) on delete cascade,
  place_id text not null,
  -- The FUNKY "night" (it rolls over at 2 PM Eastern).
  night date not null,
  via text not null default 'going' check (via in ('going', 'story')),
  created_at timestamptz not null default now(),
  primary key (user_id, place_id, night)
);

create index if not exists place_visits_user_idx on public.place_visits (user_id);

alter table public.place_visits enable row level security;
grant select on public.place_visits to authenticated;

drop policy if exists "See your own place visits" on public.place_visits;
create policy "See your own place visits"
  on public.place_visits for select to authenticated
  using (user_id = auth.uid());

create or replace function public.funky_night(ts timestamptz)
returns date
language sql
stable
as $$
  select ((ts at time zone 'America/New_York') - interval '14 hours')::date
$$;

create or replace function public.try_date(t text)
returns date
language plpgsql
immutable
as $$
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return t::date;
exception when others then
  return null;
end;
$$;

-- A Story posted at a place.
create or replace function public.record_story_visit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.place_id is not null and new.place_id <> 'main' then
    insert into public.place_visits (user_id, place_id, night, via, created_at)
    values (new.uid, lower(new.place_id), public.funky_night(new.created_at), 'story', new.created_at)
    on conflict (user_id, place_id, night) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_record_visit on public.stories;
create trigger stories_record_visit
  after insert on public.stories
  for each row execute function public.record_story_visit();

-- "I'm going" on a place (profiles.move holds tonight's pick).
create or replace function public.record_going_visit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  n date;
begin
  if new.move is not null and new.move <> 'in' and new.move <> ''
     and (tg_op = 'INSERT'
          or new.move is distinct from old.move
          or new.move_session is distinct from old.move_session) then
    n := coalesce(public.try_date(new.move_session), public.funky_night(now()));
    insert into public.place_visits (user_id, place_id, night, via)
    values (new.id, lower(new.move), n, 'going')
    on conflict (user_id, place_id, night) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_record_going_visit on public.profiles;
create trigger profiles_record_going_visit
  after insert or update of move, move_session on public.profiles
  for each row execute function public.record_going_visit();

-- Back-fill from Stories already posted at places, and tonight's picks.
insert into public.place_visits (user_id, place_id, night, via, created_at)
select s.uid, lower(s.place_id), public.funky_night(s.created_at), 'story', min(s.created_at)
  from public.stories s
 where s.place_id is not null and s.place_id <> 'main'
 group by s.uid, lower(s.place_id), public.funky_night(s.created_at)
on conflict (user_id, place_id, night) do nothing;

insert into public.place_visits (user_id, place_id, night, via)
select p.id, lower(p.move), public.try_date(p.move_session), 'going'
  from public.profiles p
 where p.move is not null and p.move <> 'in' and p.move <> ''
   and public.try_date(p.move_session) is not null
   and exists (select 1 from auth.users u where u.id = p.id)
on conflict (user_id, place_id, night) do nothing;

-- ======================== phase28.sql ========================
-- ============================================================
-- Phase 28:
--   1) One poll a day per person (the night rolls over at 2 PM Eastern).
--      Deleting your poll doesn't give you another one that night.
--      FUNKY admins aren't limited.
--   2) Text-only Stories never become Memories (can't be saved to the
--      Timeline). Only photo and video Stories are kept.
-- Safe to run more than once. Needs phase 27 (funky_night).
-- ============================================================

create table if not exists public.poll_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  night date not null,
  created_at timestamptz not null default now(),
  primary key (user_id, night)
);

-- Nobody reads or writes this directly; only the trigger below does.
alter table public.poll_daily enable row level security;

create or replace function public.one_poll_a_day()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  insert into public.poll_daily (user_id, night)
  values (auth.uid(), public.funky_night(now()))
  on conflict (user_id, night) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'You can only post one poll a day. Check back after the 2 PM reset.';
  end if;
  return new;
end;
$$;

drop trigger if exists one_poll_a_day on public.polls;
create trigger one_poll_a_day
  before insert on public.polls
  for each row execute function public.one_poll_a_day();

-- Anyone who already posted a poll tonight has used tonight's.
insert into public.poll_daily (user_id, night)
select distinct p.by_uid, public.funky_night(p.created_at)
  from public.polls p
 where p.by_uid is not null
   and p.created_at > now() - interval '2 days'
   and exists (select 1 from auth.users u where u.id = p.by_uid)
on conflict (user_id, night) do nothing;

-- Text-only Stories can't be saved as Memories.
create or replace function public.text_stories_not_memories()
returns trigger
language plpgsql
as $$
begin
  if new.media_path is null then
    new.saved_to_timeline := false;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_text_not_memories on public.stories;
create trigger stories_text_not_memories
  before insert or update on public.stories
  for each row execute function public.text_stories_not_memories();

update public.stories set saved_to_timeline = false
 where media_path is null and saved_to_timeline;

-- ======================== phase29.sql ========================
-- ============================================================
-- Phase 29: Posts. A few photos and a caption, optionally tagged at a
-- place, with likes and comments. Everyone sees every post in their area
-- (the app shows the posts inside your radius). Unlike Stories, posts
-- don't disappear after 24 hours.
-- Guests can look but not post, like or comment. Posts can be reported
-- (they go to the same admin review list as reported Stories).
-- Safe to run more than once. Needs phases 15 (is_guest), 26 and 27.
-- ============================================================

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null references public.profiles (id) on delete cascade,
  caption text not null default '' check (char_length(caption) <= 500),
  place_id text,
  place_name text check (place_name is null or char_length(place_name) <= 80),
  lat double precision not null,
  lng double precision not null,
  photo_paths text[] not null check (array_length(photo_paths, 1) between 1 and 5),
  created_at timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_uid_idx on public.posts (uid);

alter table public.posts enable row level security;
grant select, insert, delete on public.posts to authenticated;

drop policy if exists "See posts" on public.posts;
create policy "See posts" on public.posts for select to authenticated using (true);

drop policy if exists "Post as yourself" on public.posts;
create policy "Post as yourself" on public.posts for insert to authenticated
  with check (auth.uid() = uid and not public.is_banned() and not public.is_guest());

drop policy if exists "Delete your own post (admins any)" on public.posts;
create policy "Delete your own post (admins any)" on public.posts for delete to authenticated
  using (auth.uid() = uid or public.is_admin());

drop trigger if exists rate_limit_posts on public.posts;
create trigger rate_limit_posts before insert on public.posts
  for each row execute procedure public.rate_limit('uid', '86400', '10');

-- ---- Likes ------------------------------------------------------------

create table if not exists public.post_likes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_likes enable row level security;
grant select, insert, delete on public.post_likes to authenticated;

drop policy if exists "See post likes" on public.post_likes;
create policy "See post likes" on public.post_likes for select to authenticated using (true);

drop policy if exists "Like as yourself" on public.post_likes;
create policy "Like as yourself" on public.post_likes for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned() and not public.is_guest());

drop policy if exists "Unlike your own like" on public.post_likes;
create policy "Unlike your own like" on public.post_likes for delete to authenticated
  using (auth.uid() = user_id);

-- ---- Comments ---------------------------------------------------------

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  uid uuid not null references public.profiles (id) on delete cascade,
  text text not null check (char_length(btrim(text)) between 1 and 300),
  created_at timestamptz not null default now()
);

create index if not exists post_comments_post_idx on public.post_comments (post_id, created_at);

alter table public.post_comments enable row level security;
grant select, insert, delete on public.post_comments to authenticated;

drop policy if exists "See comments" on public.post_comments;
create policy "See comments" on public.post_comments for select to authenticated using (true);

drop policy if exists "Comment as yourself" on public.post_comments;
create policy "Comment as yourself" on public.post_comments for insert to authenticated
  with check (auth.uid() = uid and not public.is_banned() and not public.is_guest());

-- Your own comment, any comment on your own post, or an admin.
drop policy if exists "Delete a comment" on public.post_comments;
create policy "Delete a comment" on public.post_comments for delete to authenticated
  using (
    auth.uid() = uid
    or public.is_admin()
    or exists (select 1 from public.posts p where p.id = post_id and p.uid = auth.uid())
  );

drop trigger if exists rate_limit_post_comments on public.post_comments;
create trigger rate_limit_post_comments before insert on public.post_comments
  for each row execute procedure public.rate_limit('uid', '60', '8');

-- Tell the poster when someone comments.
create or replace function public.notify_post_comment()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  owner uuid;
  who text;
begin
  select uid into owner from public.posts where id = new.post_id;
  if owner is null or owner = new.uid then
    return new;
  end if;
  select handle into who from public.profiles where id = new.uid;
  perform public.push_notify(
    owner, 'post_comment', '@' || coalesce(who, 'someone') || ' commented on your post',
    left(new.text, 120),
    jsonb_build_object('post_id', new.post_id, 'from', new.uid));
  return new;
end;
$$;

drop trigger if exists post_comments_notify on public.post_comments;
create trigger post_comments_notify
  after insert on public.post_comments
  for each row execute function public.notify_post_comment();

-- ---- Photos (public bucket: posts are meant to be seen) -----------------

insert into storage.buckets (id, name, public)
values ('posts', 'posts', true)
on conflict (id) do update set public = true;

drop policy if exists "Upload your own post photos" on storage.objects;
create policy "Upload your own post photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'posts'
    and (storage.foldername(name)) [1] = auth.uid()::text
    and not public.is_guest()
  );

drop policy if exists "Read post photos" on storage.objects;
create policy "Read post photos"
  on storage.objects for select to authenticated
  using (bucket_id = 'posts');

drop policy if exists "Delete your own post photos" on storage.objects;
create policy "Delete your own post photos"
  on storage.objects for delete to authenticated
  using (bucket_id = 'posts' and ((storage.foldername(name)) [1] = auth.uid()::text or public.is_admin()));

-- ---- Reporting a post (same admin list as Story reports) ----------------

alter table public.story_reports add column if not exists post_id uuid references public.posts (id) on delete set null;
alter table public.story_reports add column if not exists kind text not null default 'story';
alter table public.story_reports drop constraint if exists story_reports_kind_check;
alter table public.story_reports add constraint story_reports_kind_check check (kind in ('story', 'post'));

create unique index if not exists post_report_one_open
  on public.story_reports (reporter_id, post_id) where status = 'open' and post_id is not null;

create or replace function public.report_post(p_post uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
  p public.posts%rowtype;
  rid uuid;
  who text;
  a record;
begin
  if uid is null then return 'Sign in to report a post.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  select * into p from public.posts where id = p_post;
  if not found then return 'That post isn''t up anymore.'; end if;
  if p.uid = uid then return 'That''s your own post.'; end if;
  if exists (select 1 from public.story_reports
              where reporter_id = uid and post_id = p_post and status = 'open') then
    return 'You already reported this post. The FUNKY team will take a look.';
  end if;
  if (select count(*) from public.story_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 15 then
    return 'That''s a lot of reports for one day. Try again tomorrow.';
  end if;

  insert into public.story_reports (
    kind, post_id, reporter_id, poster_id, reason,
    story_text, story_media_path, story_is_video, story_anon, story_place_name, story_created_at)
  values (
    'post', p.id, uid, p.uid, r,
    left(p.caption, 300), p.photo_paths[1], false, false, p.place_name, p.created_at)
  returning id into rid;

  if (select count(*) from public.story_reports where post_id = p.id and status = 'open') = 1 then
    select handle into who from public.profiles where id = p.uid;
    for a in
      select pr.id from public.profiles pr
       where pr.is_admin
          or pr.id in (select u.id from auth.users u where lower(u.email) = 'seanauble@icloud.com')
    loop
      if a.id <> uid then
        perform public.push_notify(
          a.id, 'story_report', 'Post reported',
          '@' || coalesce(who, 'someone') || '''s post was reported: ' || r,
          jsonb_build_object('report_id', rid, 'post_id', p.id));
      end if;
    end loop;
  end if;
  return null;
end;
$$;

grant execute on function public.report_post(uuid, text) to authenticated;

-- Admin: close a report (and the others on the same Story/post).
-- p_remove = true also deletes that Story or post and tells the poster.
create or replace function public.resolve_story_report(p_id uuid, p_remove boolean default false)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  rep public.story_reports%rowtype;
begin
  if not public.is_admin() then return 'Admins only.'; end if;
  select * into rep from public.story_reports where id = p_id;
  if not found then return 'That report is gone.'; end if;

  update public.story_reports
     set status = 'resolved',
         outcome = case when p_remove then 'removed' else 'dismissed' end
   where status = 'open'
     and (id = p_id
          or (rep.story_id is not null and story_id = rep.story_id)
          or (rep.post_id is not null and post_id = rep.post_id));

  if p_remove then
    if rep.story_id is not null then
      delete from public.stories where id = rep.story_id;
    end if;
    if rep.post_id is not null then
      delete from public.posts where id = rep.post_id;
    end if;
    if rep.poster_id is not null then
      perform public.push_notify(
        rep.poster_id, 'moderation',
        case when rep.kind = 'post' then 'Your post was removed' else 'Your story was removed' end,
        'One of your ' || case when rep.kind = 'post' then 'posts' else 'stories' end
          || ' broke the FUNKY community rules (' || rep.reason || ') and was taken down.',
        '{}'::jsonb);
    end if;
  end if;
  return null;
end;
$$;

grant execute on function public.resolve_story_report(uuid, boolean) to authenticated;

-- ---- Live updates -------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['posts', 'post_likes', 'post_comments'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ======================== phase30.sql ========================
-- ============================================================
-- Phase 30: posts get dislikes, text-only posts ("Anyone up for
-- trivia?"), and the town they were posted in.
--   * A post can be just text (no photos), or 1-5 photos with a caption.
--   * Like or dislike a post (one or the other, never both). Feeds sort
--     by likes minus dislikes.
-- Safe to run more than once. Needs phase 29.
-- ============================================================

alter table public.posts add column if not exists area_name text;
alter table public.posts drop constraint if exists posts_area_name_len;
alter table public.posts add constraint posts_area_name_len
  check (area_name is null or char_length(area_name) <= 60);

alter table public.posts alter column photo_paths set default '{}';
alter table public.posts drop constraint if exists posts_photo_paths_check;
alter table public.posts drop constraint if exists posts_has_content;
alter table public.posts add constraint posts_has_content check (
  coalesce(array_length(photo_paths, 1), 0) <= 5
  and (coalesce(array_length(photo_paths, 1), 0) >= 1 or char_length(btrim(caption)) >= 1)
);

-- ---- Dislikes -----------------------------------------------------------

create table if not exists public.post_dislikes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_dislikes enable row level security;
grant select, insert, delete on public.post_dislikes to authenticated;

drop policy if exists "See post dislikes" on public.post_dislikes;
create policy "See post dislikes" on public.post_dislikes for select to authenticated using (true);

drop policy if exists "Dislike as yourself" on public.post_dislikes;
create policy "Dislike as yourself" on public.post_dislikes for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned() and not public.is_guest());

drop policy if exists "Undo your own dislike" on public.post_dislikes;
create policy "Undo your own dislike" on public.post_dislikes for delete to authenticated
  using (auth.uid() = user_id);

-- A like cancels your dislike and the other way round.
create or replace function public.post_vote_exclusive()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if tg_table_name = 'post_likes' then
    delete from public.post_dislikes where post_id = new.post_id and user_id = new.user_id;
  else
    delete from public.post_likes where post_id = new.post_id and user_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists post_likes_exclusive on public.post_likes;
create trigger post_likes_exclusive
  after insert on public.post_likes
  for each row execute function public.post_vote_exclusive();

drop trigger if exists post_dislikes_exclusive on public.post_dislikes;
create trigger post_dislikes_exclusive
  after insert on public.post_dislikes
  for each row execute function public.post_vote_exclusive();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'post_dislikes'
  ) then
    alter publication supabase_realtime add table public.post_dislikes;
  end if;
end $$;

-- ======================== phase31.sql ========================
-- ============================================================
-- Phase 31:
--   1) Delete your account from inside the app (Apple requires it).
--   2) Block someone: they can't message you, friend you or comment on
--      your posts, and the app hides each of you from the other.
--   3) Profiles remember when someone confirmed they're 21+ and agreed
--      to the Terms.
--   4) Events: a post can be an event (name, date & time, cover) and
--      people can tap "I'm going".
--   5) Find friends from your contacts (matches email addresses, sent as
--      hashes, never stored).
--   6) More notifications: "3 friends are heading to Charlie's",
--      "Your post got 10 likes", "@x posted".
-- Safe to run more than once. Needs phases 27 (funky_night) and 29/30.
-- ============================================================

-- ---- 1) Delete my account ---------------------------------------------

create or replace function public.delete_my_account()
returns text
language plpgsql
security definer set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return 'Not signed in.'; end if;
  -- Old projects tie uploaded files to their owner; let go of them first
  -- so the delete below can't be blocked by that.
  begin
    execute 'update storage.objects set owner = null where owner = $1' using uid;
  exception when others then
    null;
  end;
  -- Everything of yours (profile, stories, posts, messages, …) is removed
  -- with the account.
  delete from auth.users where id = uid;
  return null;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---- 2) Blocking ---------------------------------------------------------

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;
grant select on public.blocks to authenticated;

-- You see who you blocked, and who blocked you (so both apps hide each other).
drop policy if exists "See blocks you're part of" on public.blocks;
create policy "See blocks you're part of" on public.blocks for select to authenticated
  using (auth.uid() = blocker_id or auth.uid() = blocked_id);

create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  )
$$;

create or replace function public.block_user(p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return 'Sign in first.'; end if;
  if p_user is null or p_user = uid then return 'You can''t block yourself.'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return 'That account isn''t around anymore.'; end if;
  insert into public.blocks (blocker_id, blocked_id) values (uid, p_user)
  on conflict do nothing;
  -- No more friendship or pending requests either way.
  delete from public.friendships
   where (requester_id = uid and addressee_id = p_user)
      or (requester_id = p_user and addressee_id = uid);
  return null;
end;
$$;

create or replace function public.unblock_user(p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then return 'Sign in first.'; end if;
  delete from public.blocks where blocker_id = auth.uid() and blocked_id = p_user;
  return null;
end;
$$;

grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;

-- Blocked = no messages, friend requests or comments between you.
create or replace function public.stop_if_blocked()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  a uuid;
  b uuid;
begin
  if tg_table_name = 'messages' then
    a := new.sender_id; b := new.recipient_id;
  elsif tg_table_name = 'friendships' then
    a := new.requester_id; b := new.addressee_id;
  elsif tg_table_name = 'post_comments' then
    a := new.uid; select p.uid into b from public.posts p where p.id = new.post_id;
  end if;
  if a is not null and b is not null and a <> b and public.is_blocked_between(a, b) then
    raise exception 'You can''t do that: one of you blocked the other.';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_stop_if_blocked on public.messages;
create trigger messages_stop_if_blocked before insert on public.messages
  for each row execute function public.stop_if_blocked();

drop trigger if exists friendships_stop_if_blocked on public.friendships;
create trigger friendships_stop_if_blocked before insert on public.friendships
  for each row execute function public.stop_if_blocked();

drop trigger if exists post_comments_stop_if_blocked on public.post_comments;
create trigger post_comments_stop_if_blocked before insert on public.post_comments
  for each row execute function public.stop_if_blocked();

-- ---- 3) 21+ and Terms ------------------------------------------------------

alter table public.profiles add column if not exists age_confirmed_at timestamptz;
alter table public.profiles add column if not exists terms_accepted_at timestamptz;

-- ---- 4) Events -----------------------------------------------------------

alter table public.posts add column if not exists event_title text;
alter table public.posts add column if not exists event_at timestamptz;
alter table public.posts add column if not exists event_cover text;
alter table public.posts drop constraint if exists posts_event_fields;
alter table public.posts add constraint posts_event_fields check (
  (event_title is null or char_length(event_title) between 1 and 60)
  and (event_cover is null or char_length(event_cover) <= 20)
);
create index if not exists posts_event_at_idx on public.posts (event_at) where event_at is not null;

-- An event can be just its name and time (no photo or caption needed).
alter table public.posts drop constraint if exists posts_has_content;
alter table public.posts add constraint posts_has_content check (
  coalesce(array_length(photo_paths, 1), 0) <= 5
  and (coalesce(array_length(photo_paths, 1), 0) >= 1
       or char_length(btrim(caption)) >= 1
       or event_title is not null)
);

create table if not exists public.event_going (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.event_going enable row level security;
grant select, insert, delete on public.event_going to authenticated;

drop policy if exists "See who's going" on public.event_going;
create policy "See who's going" on public.event_going for select to authenticated using (true);

drop policy if exists "Say you're going" on public.event_going;
create policy "Say you're going" on public.event_going for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned() and not public.is_guest());

drop policy if exists "Take back going" on public.event_going;
create policy "Take back going" on public.event_going for delete to authenticated
  using (auth.uid() = user_id);

-- ---- 5) Find friends from contacts ---------------------------------------

-- p_hashes: sha256 hex of lowercased email addresses from your contacts.
create or replace function public.match_contacts(p_hashes text[])
returns table (id uuid, handle text)
language sql
stable
security definer set search_path = public, auth
as $$
  select p.id, p.handle
    from public.profiles p
    join auth.users u on u.id = p.id
   where auth.uid() is not null
     and p.id <> auth.uid()
     and coalesce(p.banned, false) = false
     and u.email is not null
     and encode(sha256(convert_to(lower(btrim(u.email)), 'UTF8')), 'hex') = any (p_hashes[1:2000])
     and not public.is_blocked_between(auth.uid(), p.id)
   limit 200
$$;

revoke all on function public.match_contacts(text[]) from public, anon;
grant execute on function public.match_contacts(text[]) to authenticated;

-- ---- 6) Notifications -----------------------------------------------------

-- "3 friends are heading to Charlie's" — sent to each friend of whoever
-- just picked a place, when 2, 3, 5 or 10 of their friends are going there
-- tonight (once per place and number per night).
create or replace function public.notify_friends_going()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  f record;
  n integer;
  pname text;
begin
  if new.move is null or new.move in ('in', '')
     or (tg_op = 'UPDATE' and new.move is not distinct from old.move
         and new.move_session is not distinct from old.move_session) then
    return new;
  end if;
  select name into pname from public.places where id::text = lower(new.move);
  if pname is null then return new; end if;

  for f in
    select case when fr.requester_id = new.id then fr.addressee_id else fr.requester_id end as friend_id
      from public.friendships fr
     where fr.status = 'accepted' and (fr.requester_id = new.id or fr.addressee_id = new.id)
  loop
    select count(*) into n
      from public.friendships fr2
      join public.profiles p
        on p.id = case when fr2.requester_id = f.friend_id then fr2.addressee_id else fr2.requester_id end
     where fr2.status = 'accepted'
       and (fr2.requester_id = f.friend_id or fr2.addressee_id = f.friend_id)
       and lower(p.move) = lower(new.move)
       and p.move_session is not distinct from new.move_session;
    if n in (2, 3, 5, 10) and not exists (
      select 1 from public.notifications nt
       where nt.user_id = f.friend_id and nt.kind = 'friends_going'
         and nt.data ->> 'place_id' = lower(new.move)
         and nt.data ->> 'count' = n::text
         and nt.created_at > now() - interval '14 hours'
    ) then
      perform public.push_notify(
        f.friend_id, 'friends_going',
        n || ' friends are heading to ' || pname,
        'See who''s going tonight.',
        jsonb_build_object('place_id', lower(new.move), 'count', n::text));
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists profiles_notify_friends_going on public.profiles;
create trigger profiles_notify_friends_going
  after insert or update of move, move_session on public.profiles
  for each row execute function public.notify_friends_going();

-- "Your post got 10 likes" at 5, 10, 25, 50 and 100 likes.
create or replace function public.notify_post_likes()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  owner uuid;
  n integer;
begin
  select uid into owner from public.posts where id = new.post_id;
  if owner is null or owner = new.user_id then return new; end if;
  select count(*) into n from public.post_likes where post_id = new.post_id;
  if n in (5, 10, 25, 50, 100) and not exists (
    select 1 from public.notifications nt
     where nt.user_id = owner and nt.kind = 'post_like'
       and nt.data ->> 'post_id' = new.post_id::text and nt.data ->> 'count' = n::text
  ) then
    perform public.push_notify(
      owner, 'post_like', 'Your post got ' || n || ' likes 🔥', 'People in your area are into it.',
      jsonb_build_object('post_id', new.post_id, 'count', n::text));
  end if;
  return new;
end;
$$;

drop trigger if exists post_likes_notify on public.post_likes;
create trigger post_likes_notify
  after insert on public.post_likes
  for each row execute function public.notify_post_likes();

-- "@x posted" to their friends (at most once every 3 hours per friend).
create or replace function public.notify_friend_posted()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  f record;
  who text;
  what text;
begin
  select handle into who from public.profiles where id = new.uid;
  what := case
    when new.event_title is not null then 'New event: ' || new.event_title
    when char_length(btrim(new.caption)) > 0 then left(new.caption, 100)
    else 'Tap to see it.'
  end;
  for f in
    select case when fr.requester_id = new.uid then fr.addressee_id else fr.requester_id end as friend_id
      from public.friendships fr
     where fr.status = 'accepted' and (fr.requester_id = new.uid or fr.addressee_id = new.uid)
  loop
    if not exists (
      select 1 from public.notifications nt
       where nt.user_id = f.friend_id and nt.kind = 'friend_post'
         and nt.data ->> 'from' = new.uid::text
         and nt.created_at > now() - interval '3 hours'
    ) and not public.is_blocked_between(f.friend_id, new.uid) then
      perform public.push_notify(
        f.friend_id, 'friend_post', '@' || coalesce(who, 'A friend') || ' posted', what,
        jsonb_build_object('post_id', new.id, 'from', new.uid));
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists posts_notify_friends on public.posts;
create trigger posts_notify_friends
  after insert on public.posts
  for each row execute function public.notify_friend_posted();

-- ---- Live updates ---------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['blocks', 'event_going'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ======================== phase32.sql ========================
-- ============================================================
-- Phase 32:
--   1) Crash reports: when the app hits an error it sends a short report
--      (what went wrong, where, which build). Only admins can read them,
--      in the admin panel.
--   2) Top posts win points: each night (2 PM to 2 PM), the 3 best posts
--      in each area (about 30 miles across) by likes minus dislikes get
--      500 / 300 / 150 Funky points. Awarded the first time anyone opens
--      the app after the night ends. A post needs at least 1 net like.
-- Safe to run more than once. Needs phases 27 (funky_night), 29, 30.
-- ============================================================

-- ---- 1) Crash reports -----------------------------------------------------

create table if not exists public.crash_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid default auth.uid(),
  message text not null check (char_length(message) <= 1000),
  stack text check (stack is null or char_length(stack) <= 6000),
  context text check (context is null or char_length(context) <= 500),
  fatal boolean not null default false,
  build text check (build is null or char_length(build) <= 20),
  platform text check (platform is null or char_length(platform) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists crash_reports_created_idx on public.crash_reports (created_at desc);

alter table public.crash_reports enable row level security;
grant insert on public.crash_reports to anon, authenticated;
grant select, delete on public.crash_reports to authenticated;

drop policy if exists "Anyone can send a crash report" on public.crash_reports;
create policy "Anyone can send a crash report" on public.crash_reports for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

drop policy if exists "Admins read crash reports" on public.crash_reports;
create policy "Admins read crash reports" on public.crash_reports for select to authenticated
  using (public.is_admin());

drop policy if exists "Admins clear crash reports" on public.crash_reports;
create policy "Admins clear crash reports" on public.crash_reports for delete to authenticated
  using (public.is_admin());

-- Don't let a crash loop (or anyone) flood the table: past 300 reports in
-- 10 minutes, extra ones are quietly dropped. Old reports go after 30 days.
create or replace function public.crash_reports_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if (select count(*) from public.crash_reports where created_at > now() - interval '10 minutes') >= 300 then
    return null;
  end if;
  delete from public.crash_reports where created_at < now() - interval '30 days';
  return new;
end;
$$;

drop trigger if exists crash_reports_guard on public.crash_reports;
create trigger crash_reports_guard before insert on public.crash_reports
  for each row execute function public.crash_reports_guard();

-- ---- 2) Top posts win points ------------------------------------------------

-- Which area a spot is in: a grid of cells about 30 miles across.
create or replace function public.post_region(lat double precision, lng double precision)
returns text
language sql
immutable
as $$
  select floor(lat / 0.45)::int || ':' || floor(lng / 0.55)::int
$$;

create table if not exists public.post_awards (
  night date not null,
  region text not null,
  rank smallint not null check (rank between 1 and 3),
  post_id uuid references public.posts (id) on delete set null,
  user_id uuid references auth.users (id) on delete cascade,
  points integer not null,
  score integer not null,
  created_at timestamptz not null default now(),
  primary key (night, region, rank)
);

alter table public.post_awards enable row level security;
grant select on public.post_awards to authenticated;

drop policy if exists "See post awards" on public.post_awards;
create policy "See post awards" on public.post_awards for select to authenticated using (true);

-- Hands out last few nights' awards that haven't been given yet. Safe to
-- call any number of times, from anyone's phone. Returns how many it gave.
create or replace function public.award_top_posts()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  tonight date := public.funky_night(now());
  n date;
  r record;
  pts integer;
  inserted integer;
  given integer := 0;
begin
  -- Points are normally admin-only on profiles; this is the server itself
  -- awarding them, so act without the caller's identity from here on.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);

  for n in select d::date from generate_series(tonight - 3, tonight - 1, interval '1 day') d loop
    for r in
      select ranked.*
        from (
          select scored.*,
                 row_number() over (partition by scored.region order by scored.score desc, scored.created_at asc) as rk
            from (
              select p.id, p.uid, p.created_at,
                     public.post_region(p.lat, p.lng) as region,
                     (select count(*) from public.post_likes l where l.post_id = p.id)
                       - (select count(*) from public.post_dislikes d2 where d2.post_id = p.id) as score
                from public.posts p
                join public.profiles pr on pr.id = p.uid
               where public.funky_night(p.created_at) = n
                 and not coalesce(pr.banned, false)
            ) scored
        ) ranked
       where ranked.rk <= 3 and ranked.score >= 1
    loop
      pts := case r.rk when 1 then 500 when 2 then 300 else 150 end;
      insert into public.post_awards (night, region, rank, post_id, user_id, points, score)
      values (n, r.region, r.rk, r.id, r.uid, pts, r.score)
      on conflict do nothing;
      get diagnostics inserted = row_count;
      if inserted = 1 then
        update public.profiles set bonus_points = bonus_points + pts where id = r.uid;
        perform public.push_notify(
          r.uid, 'post_award',
          'Your post was #' || r.rk || ' last night 🏆',
          '+' || pts || ' Funky points. Keep it up.',
          jsonb_build_object('post_id', r.id, 'rank', r.rk::text));
        given := given + 1;
      end if;
    end loop;
  end loop;
  return given;
end;
$$;

grant execute on function public.award_top_posts() to authenticated;

-- ======================== phase33.sql ========================
-- ============================================================
-- Phase 33:
--   1) Upcoming: parties, events, tailgates and frat parties can have a
--      date and time. They show under Upcoming until their night, then
--      move to Tonight. An event can be held at a bar or club (trivia,
--      karaoke...). People can say they're going ahead of time.
--   2) Guests (no account): can look around and Live Chat anonymously,
--      but can't post, comment, like, RSVP, add friends or message.
--   3) Live Chat: replies, sharing a spot or a poll, GIFs, and a count of
--      how many people are online in your area.
--   4) Profile pictures: new accounts start with a random FUNKY avatar.
--   5) Stories: any recent Story still missing a location gets one, so
--      "your radius reaches it" works for every Story.
-- Safe to run more than once. Needs phases 2-32.
-- ============================================================

-- ---- 1) Dated places, events at bars, RSVPs ---------------------------

alter table public.places add column if not exists starts_at timestamptz;
alter table public.places add column if not exists event_type text;
alter table public.places add column if not exists host_place_id uuid references public.places (id) on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'places_event_type_check') then
    alter table public.places add constraint places_event_type_check
      check (event_type is null or event_type in ('trivia', 'karaoke', 'live_music', 'dj', 'happy_hour', 'game_watch', 'comedy', 'other'));
  end if;
  -- No dates more than 60 days out.
  if not exists (select 1 from pg_constraint where conname = 'places_starts_at_check') then
    alter table public.places add constraint places_starts_at_check
      check (starts_at is null or starts_at < created_at + interval '61 days');
  end if;
end;
$$;

create index if not exists places_starts_at_idx on public.places (starts_at) where starts_at is not null;
create index if not exists places_host_idx on public.places (host_place_id) where host_place_id is not null;

-- A dated place stays until a day after it starts (an undated one: a day
-- after it was added). FUNKY-verified places always stay.
create or replace function public.purge_stale_places()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  with del as (
    delete from public.places p
    where p.admin_verified = false
      and greatest(p.created_at, coalesce(p.starts_at, p.created_at)) < now() - interval '24 hours'
    returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_stale_places() to authenticated;

create table if not exists public.place_rsvps (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

create index if not exists place_rsvps_user_idx on public.place_rsvps (user_id);

alter table public.place_rsvps enable row level security;
grant select, insert, delete on public.place_rsvps to authenticated;

drop policy if exists "See who's going ahead" on public.place_rsvps;
create policy "See who's going ahead" on public.place_rsvps for select to authenticated using (true);

drop policy if exists "Say you're going ahead" on public.place_rsvps;
create policy "Say you're going ahead" on public.place_rsvps for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists "Take back going ahead" on public.place_rsvps;
create policy "Take back going ahead" on public.place_rsvps for delete to authenticated
  using (user_id = auth.uid());

-- ---- 2) Guests ---------------------------------------------------------

drop policy if exists "Guests can't post" on public.posts;
create policy "Guests can't post" on public.posts as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't like posts" on public.post_likes;
create policy "Guests can't like posts" on public.post_likes as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't dislike posts" on public.post_dislikes;
create policy "Guests can't dislike posts" on public.post_dislikes as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't comment" on public.post_comments;
create policy "Guests can't comment" on public.post_comments as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't say going" on public.event_going;
create policy "Guests can't say going" on public.event_going as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't RSVP" on public.place_rsvps;
create policy "Guests can't RSVP" on public.place_rsvps as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't post polls" on public.polls;
create policy "Guests can't post polls" on public.polls as restrictive for insert to authenticated
  with check (not public.is_guest());

-- Guests can Live Chat, but only anonymously.
drop policy if exists "Guests chat anonymously" on public.chat_messages;
create policy "Guests chat anonymously" on public.chat_messages as restrictive for insert to authenticated
  with check (not public.is_guest() or anon);

-- ---- 3) Live Chat: replies, shared spots and polls, GIFs ----------------

alter table public.chat_messages add column if not exists reply_to uuid references public.chat_messages (id) on delete set null;
alter table public.chat_messages add column if not exists reply_text text;
alter table public.chat_messages add column if not exists reply_handle text;
alter table public.chat_messages add column if not exists place_id uuid references public.places (id) on delete set null;
alter table public.chat_messages add column if not exists poll_id uuid references public.polls (id) on delete set null;
alter table public.chat_messages add column if not exists gif_url text;

do $$
begin
  -- A message can be just a GIF, a spot or a poll, with no words.
  alter table public.chat_messages drop constraint if exists chat_messages_text_check;
  if not exists (select 1 from pg_constraint where conname = 'chat_messages_text_ok') then
    alter table public.chat_messages add constraint chat_messages_text_ok
      check (char_length(text) <= 240
             and (char_length(text) >= 1 or gif_url is not null or place_id is not null or poll_id is not null));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'chat_messages_extras_ok') then
    alter table public.chat_messages add constraint chat_messages_extras_ok
      check ((reply_text is null or char_length(reply_text) <= 240)
             and (reply_handle is null or char_length(reply_handle) <= 40)
             and (gif_url is null or (char_length(gif_url) <= 400 and gif_url ~ '^https://(media[0-9]*|i)\.giphy\.com/')));
  end if;
end;
$$;

-- Someone replied to your Live Chat message: let them know (even if your
-- message was anonymous; the replier never learns who you are).
create or replace function public.notify_chat_reply()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  author uuid := coalesce(new.sender_id, auth.uid());
  target uuid;
  title text;
begin
  if new.reply_to is null then
    return new;
  end if;
  select coalesce(m.sender_id, a.uid) into target
    from public.chat_messages m
    left join public.chat_message_authors a on a.message_id = m.id
   where m.id = new.reply_to;
  if target is null or target = author then
    return new;
  end if;
  if new.anon or new.sender_id is null then
    title := 'Someone replied to you in live chat';
  else
    title := '@' || public.notif_handle(new.sender_id) || ' replied to you';
  end if;
  perform public.push_notify(
    target, 'mention', title,
    left(case when coalesce(new.text, '') = '' then (case when new.gif_url is not null then 'GIF' when new.place_id is not null then 'Shared a spot' else 'Shared a poll' end) else new.text end, 120),
    jsonb_build_object('chat', true, 'message_id', new.id)
  );
  return new;
end;
$$;

revoke all on function public.notify_chat_reply() from public, anon, authenticated;

drop trigger if exists notify_chat_reply on public.chat_messages;
create trigger notify_chat_reply after insert on public.chat_messages
  for each row execute function public.notify_chat_reply();

-- Who's online near you: each open app checks in about once a minute with
-- a rough location (rounded to ~1 km). Nobody can read the table; the
-- function only ever hands back a count.
create table if not exists public.presence (
  user_id uuid primary key references auth.users (id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  seen_at timestamptz not null default now()
);

create index if not exists presence_seen_idx on public.presence (seen_at);

alter table public.presence enable row level security;
revoke all on public.presence from anon, authenticated;

create or replace function public.ping_presence(p_lat double precision, p_lng double precision, p_radius_miles double precision default 10)
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  r double precision := least(greatest(coalesce(p_radius_miles, 10), 1), 5000);
  n integer;
begin
  if me is null or p_lat is null or p_lng is null then
    return 0;
  end if;
  insert into public.presence (user_id, lat, lng, seen_at)
  values (me, round(p_lat::numeric, 2)::double precision, round(p_lng::numeric, 2)::double precision, now())
  on conflict (user_id) do update set lat = excluded.lat, lng = excluded.lng, seen_at = now();

  select count(*) into n
    from public.presence pr
   where pr.seen_at > now() - interval '5 minutes'
     and 3958.8 * 2 * asin(least(1.0, sqrt(
           power(sin(radians(pr.lat - p_lat) / 2), 2)
           + cos(radians(p_lat)) * cos(radians(pr.lat)) * power(sin(radians(pr.lng - p_lng) / 2), 2)))) <= r;

  delete from public.presence where seen_at < now() - interval '1 day';
  return coalesce(n, 0);
end;
$$;

grant execute on function public.ping_presence(double precision, double precision, double precision) to authenticated;

-- App settings the app reads (just the GIF search key for now). Only
-- admins can change them.
create table if not exists public.app_config (
  key text primary key check (char_length(key) <= 40),
  value text check (value is null or char_length(value) <= 200),
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;
grant select on public.app_config to anon, authenticated;
grant insert, update, delete on public.app_config to authenticated;

drop policy if exists "Read app settings" on public.app_config;
create policy "Read app settings" on public.app_config for select to anon, authenticated
  using (key in ('giphy_key'));

drop policy if exists "Admins add app settings" on public.app_config;
create policy "Admins add app settings" on public.app_config for insert to authenticated
  with check (public.is_admin());

drop policy if exists "Admins change app settings" on public.app_config;
create policy "Admins change app settings" on public.app_config for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins remove app settings" on public.app_config;
create policy "Admins remove app settings" on public.app_config for delete to authenticated
  using (public.is_admin());

-- ---- 4) A random FUNKY avatar for every new account ----------------------

create or replace function public.random_avatar_preset()
returns text
language sql
volatile
as $$
  select 'preset:' || (array['raccoon', 'giraffe', 'seagull', 'pup', 'cat', 'blob',
                             'flame', 'star', 'ghost', 'disco', 'cloud', 'elephant'])[1 + floor(random() * 12)::int]
$$;

alter table public.profiles alter column avatar_url set default public.random_avatar_preset();

-- ---- 5) Every recent Story has a location --------------------------------

update public.stories s
   set lat = p.lat, lng = p.lng
  from public.places p
 where s.lat is null
   and s.created_at > now() - interval '7 days'
   and s.place_id is not null
   and p.id::text = lower(s.place_id);

update public.stories s
   set lat = ul.lat, lng = ul.lng
  from public.user_locations ul
 where s.lat is null
   and s.created_at > now() - interval '7 days'
   and ul.user_id = s.uid;

-- ======================== phase34.sql ========================
-- ============================================================
-- Phase 34: GIFs in direct messages and group chats.
-- Safe to run more than once. Needs phases 2, 7, 11.
-- ============================================================

alter table public.messages add column if not exists gif_url text;
alter table public.group_messages add column if not exists gif_url text;

do $$
declare
  c record;
begin
  if not exists (select 1 from pg_constraint where conname = 'messages_gif_url_ok') then
    alter table public.messages add constraint messages_gif_url_ok
      check (gif_url is null or (char_length(gif_url) <= 400 and gif_url ~ '^https://(media[0-9]*|i)\.giphy\.com/'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'group_messages_gif_url_ok') then
    alter table public.group_messages add constraint group_messages_gif_url_ok
      check (gif_url is null or (char_length(gif_url) <= 400 and gif_url ~ '^https://(media[0-9]*|i)\.giphy\.com/'));
  end if;
  -- A group message can be just a GIF: swap the old "words or a photo"
  -- rule for one that also counts a GIF.
  for c in
    select conname from pg_constraint
     where conrelid = 'public.group_messages'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%media_path IS NOT NULL%'
       and pg_get_constraintdef(oid) not like '%gif_url%'
  loop
    execute format('alter table public.group_messages drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'group_messages_has_content') then
    alter table public.group_messages add constraint group_messages_has_content
      check (char_length(text) > 0 or media_path is not null or gif_url is not null);
  end if;
end;
$$;

-- Notifications say "Sent you a GIF" instead of an empty line.
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
  elsif new.gif_url is not null and coalesce(new.text, '') = '' then
    preview := 'Sent you a GIF';
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
  elsif new.gif_url is not null and char_length(new.text) = 0 then
    preview := '@' || who || ' sent a GIF';
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

select 'FUNKY backend ready' as status;
