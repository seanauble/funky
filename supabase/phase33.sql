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
