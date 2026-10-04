-- FUNKY real-backend schema — Phase 1: accounts, friends, Stories, DMs.
--
-- How to run this: open the Supabase dashboard for this project, go to
-- the SQL Editor, paste this whole file in, and click Run. No CLI needed.
-- Safe to re-run: every statement either uses IF NOT EXISTS / ON CONFLICT,
-- or (for policies) drops-and-recreates itself first.
--
-- Not covered yet (coming in a later pass): Places/check-ins, polls, and
-- the points/badges/level-title system. Accounts, friends, Stories, and
-- DMs are the pieces the app's local mock store can't fake across two
-- different phones, so they come first.
--
-- A note on "safe to re-run": `alter publication ... add table` is NOT
-- actually idempotent on its own in Postgres — running it twice for the
-- same table throws "relation is already member of publication" and
-- aborts whatever's left in the script. Every one of those statements
-- below is wrapped in a do-block that checks pg_publication_tables first,
-- which is what actually makes this file safe to paste and run again.

-- ============================================================
-- PROFILES — one row per real account, auto-created on sign-up
-- ============================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle text unique,
  bio text not null default '',
  avatar_url text,
  points integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "Profiles are viewable by any signed-in user" on public.profiles;
create policy "Profiles are viewable by any signed-in user"
  on public.profiles for select
  to authenticated
  using (true);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id);

-- A fresh row the instant someone signs up — the app can't be trusted to
-- create its own profile row client-side (that's how you'd end up with
-- people able to create a profile as someone else), so this runs
-- server-side as part of the signup itself.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, handle)
  values (new.id, 'funky_' || substr(new.id::text, 1, 8));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================
-- FRIENDSHIPS — one row per request; status flips to accepted
-- ============================================================

create table if not exists public.friendships (
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

alter table public.friendships enable row level security;

drop policy if exists "See your own friendships" on public.friendships;
create policy "See your own friendships"
  on public.friendships for select
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "Send a friend request" on public.friendships;
create policy "Send a friend request"
  on public.friendships for insert
  to authenticated
  with check (auth.uid() = requester_id);

drop policy if exists "Accept a request or either side can cancel" on public.friendships;
create policy "Accept a request or either side can cancel"
  on public.friendships for update
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "Either side can remove a friendship" on public.friendships;
create policy "Either side can remove a friendship"
  on public.friendships for delete
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'friendships'
  ) then
    alter publication supabase_realtime add table public.friendships;
  end if;
end $$;

-- ============================================================
-- STORIES — same privacy rule as the local app: your own always
-- visible, everyone else's only if you're friends OR it's from the
-- last 24h ("tonight"). Views/likes are separate tables so counts
-- can't race and "who" can still be queried later if needed.
-- ============================================================

create table if not exists public.stories (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  text text,
  place_id text,
  place_name text,
  anon boolean not null default false,
  media_path text,
  is_video boolean not null default false,
  saved_to_timeline boolean not null default false
);

alter table public.stories enable row level security;

drop policy if exists "View your own, a friend's, or tonight's stories" on public.stories;
create policy "View your own, a friend's, or tonight's stories"
  on public.stories for select
  to authenticated
  using (
    auth.uid() = uid
    or created_at > now() - interval '24 hours'
    or exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = uid)
          or (f.addressee_id = auth.uid() and f.requester_id = uid))
    )
  );

drop policy if exists "Post your own story" on public.stories;
create policy "Post your own story"
  on public.stories for insert
  to authenticated
  with check (auth.uid() = uid);

drop policy if exists "Update your own story" on public.stories;
create policy "Update your own story"
  on public.stories for update
  to authenticated
  using (auth.uid() = uid);

drop policy if exists "Delete your own story" on public.stories;
create policy "Delete your own story"
  on public.stories for delete
  to authenticated
  using (auth.uid() = uid);

create table if not exists public.story_views (
  story_id uuid not null references public.stories (id) on delete cascade,
  viewer_id uuid not null references public.profiles (id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);
alter table public.story_views enable row level security;

drop policy if exists "See view counts on anything you can see" on public.story_views;
create policy "See view counts on anything you can see"
  on public.story_views for select to authenticated using (true);

drop policy if exists "Record your own view" on public.story_views;
create policy "Record your own view"
  on public.story_views for insert to authenticated with check (auth.uid() = viewer_id);

create table if not exists public.story_likes (
  story_id uuid not null references public.stories (id) on delete cascade,
  liker_id uuid not null references public.profiles (id) on delete cascade,
  liked_at timestamptz not null default now(),
  primary key (story_id, liker_id)
);
alter table public.story_likes enable row level security;

drop policy if exists "See like counts on anything you can see" on public.story_likes;
create policy "See like counts on anything you can see"
  on public.story_likes for select to authenticated using (true);

drop policy if exists "Like as yourself" on public.story_likes;
create policy "Like as yourself"
  on public.story_likes for insert to authenticated with check (auth.uid() = liker_id);

drop policy if exists "Remove your own like" on public.story_likes;
create policy "Remove your own like"
  on public.story_likes for delete to authenticated using (auth.uid() = liker_id);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'stories'
  ) then
    alter publication supabase_realtime add table public.stories;
  end if;
end $$;

-- story_views/story_likes also need to be in the publication, same as
-- stories itself — without this, a like/view still writes to the table
-- fine, but no other open session ever hears about it over realtime; it
-- only shows up the next time that device re-fetches (e.g. next sign-in).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'story_views'
  ) then
    alter publication supabase_realtime add table public.story_views;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'story_likes'
  ) then
    alter publication supabase_realtime add table public.story_likes;
  end if;
end $$;

-- Story photo/video storage. App uploads go under "<your-user-id>/...",
-- which is what the policies below check against — see
-- (storage.foldername(name))[1].
insert into storage.buckets (id, name, public)
values ('stories', 'stories', false)
on conflict (id) do nothing;

drop policy if exists "Upload your own story media" on storage.objects;
create policy "Upload your own story media"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'stories' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Read story media you're allowed to see" on storage.objects;
create policy "Read story media you're allowed to see"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'stories'
    and (
      (storage.foldername(name)) [1] = auth.uid()::text
      or exists (
        select 1 from public.stories s
        where s.media_path = name
          and (
            s.created_at > now() - interval '24 hours'
            or exists (
              select 1 from public.friendships f
              where f.status = 'accepted'
                and ((f.requester_id = auth.uid() and f.addressee_id = s.uid)
                  or (f.addressee_id = auth.uid() and f.requester_id = s.uid))
            )
          )
      )
    )
  );

drop policy if exists "Delete your own story media" on storage.objects;
create policy "Delete your own story media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'stories' and (storage.foldername(name)) [1] = auth.uid()::text);

-- ============================================================
-- MESSAGES — real 1:1 DMs. No "room" concept like the local mock
-- store used; sender/recipient columns are the real thing a backend
-- needs instead.
-- ============================================================

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  text text not null,
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);

alter table public.messages enable row level security;

drop policy if exists "See your own conversations" on public.messages;
create policy "See your own conversations"
  on public.messages for select
  to authenticated
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

drop policy if exists "Send a message as yourself" on public.messages;
create policy "Send a message as yourself"
  on public.messages for insert
  to authenticated
  with check (auth.uid() = sender_id);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;
