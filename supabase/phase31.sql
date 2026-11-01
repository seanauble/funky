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
