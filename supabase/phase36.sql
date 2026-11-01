-- ============================================================
-- Phase 36:
--   1) Comments: like a comment, and reply to a comment (the person you
--      answered gets a notification).
--   2) Private events: a party/event can be private. Everyone sees its name
--      and night, but the address, exact time and guest list are only for
--      people who enter the host's code. Guests RSVP Going / Maybe / Can't.
--   3) Event chat: a group chat on every party/event page for questions
--      and plans (a private event's chat is only for its guests).
-- Safe to run more than once. Needs phases 2, 15, 29, 33.
-- ============================================================

-- ---- 1) Comment likes and replies ---------------------------------------

alter table public.post_comments add column if not exists reply_to uuid references public.post_comments (id) on delete cascade;

create table if not exists public.post_comment_likes (
  comment_id uuid not null references public.post_comments (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);

alter table public.post_comment_likes enable row level security;
grant select, insert, delete on public.post_comment_likes to authenticated;

drop policy if exists "See comment likes" on public.post_comment_likes;
create policy "See comment likes" on public.post_comment_likes for select to authenticated using (true);

drop policy if exists "Like a comment as yourself" on public.post_comment_likes;
create policy "Like a comment as yourself" on public.post_comment_likes for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned() and not public.is_guest());

drop policy if exists "Unlike your own" on public.post_comment_likes;
create policy "Unlike your own" on public.post_comment_likes for delete to authenticated
  using (user_id = auth.uid());

create or replace function public.notify_comment_reply()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  parent_author uuid;
  who text;
begin
  if new.reply_to is null then
    return new;
  end if;
  select uid into parent_author from public.post_comments where id = new.reply_to;
  if parent_author is null or parent_author = new.uid then
    return new;
  end if;
  -- The post's owner already hears about every comment on it.
  if exists (select 1 from public.posts where id = new.post_id and uid = parent_author) then
    return new;
  end if;
  select handle into who from public.profiles where id = new.uid;
  perform public.push_notify(
    parent_author, 'post_comment', '@' || coalesce(who, 'someone') || ' replied to your comment',
    left(new.text, 120),
    jsonb_build_object('post_id', new.post_id, 'from', new.uid));
  return new;
end;
$$;

revoke all on function public.notify_comment_reply() from public, anon, authenticated;

drop trigger if exists post_comments_reply_notify on public.post_comments;
create trigger post_comments_reply_notify
  after insert on public.post_comments
  for each row execute function public.notify_comment_reply();

-- ---- 2) Private events ------------------------------------------------------

alter table public.places add column if not exists is_private boolean not null default false;

-- The real address, spot and time, plus the code. Only the host and people
-- who entered the code can read it (the places row itself only has a rough
-- spot, so the event can still show up nearby).
create table if not exists public.private_event_details (
  place_id uuid primary key references public.places (id) on delete cascade,
  address text check (address is null or char_length(address) <= 120),
  lat double precision,
  lng double precision,
  starts_at timestamptz,
  passcode text not null check (char_length(passcode) between 3 and 20),
  created_at timestamptz not null default now()
);

create table if not exists public.event_guests (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  status text not null default 'going' check (status in ('going', 'maybe', 'cant', 'unlocked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

create index if not exists event_guests_user_idx on public.event_guests (user_id);

create table if not exists public.event_unlock_attempts (
  user_id uuid not null,
  place_id uuid not null,
  at timestamptz not null default now()
);

create index if not exists event_unlock_attempts_idx on public.event_unlock_attempts (user_id, at);

alter table public.event_unlock_attempts enable row level security;
revoke all on public.event_unlock_attempts from anon, authenticated;

-- Host, someone who entered the code, or an admin.
create or replace function public.is_event_insider(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select public.is_admin()
      or exists (select 1 from public.places where id = p and by_uid = auth.uid())
      or exists (select 1 from public.event_guests where place_id = p and user_id = auth.uid())
$$;

grant execute on function public.is_event_insider(uuid) to authenticated;

alter table public.private_event_details enable row level security;
grant select, insert, update, delete on public.private_event_details to authenticated;

drop policy if exists "Insiders see private details" on public.private_event_details;
create policy "Insiders see private details" on public.private_event_details for select to authenticated
  using (public.is_event_insider(place_id));

drop policy if exists "Host adds private details" on public.private_event_details;
create policy "Host adds private details" on public.private_event_details for insert to authenticated
  with check (exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

drop policy if exists "Host changes private details" on public.private_event_details;
create policy "Host changes private details" on public.private_event_details for update to authenticated
  using (exists (select 1 from public.places where id = place_id and by_uid = auth.uid()))
  with check (exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

drop policy if exists "Host removes private details" on public.private_event_details;
create policy "Host removes private details" on public.private_event_details for delete to authenticated
  using (exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

alter table public.event_guests enable row level security;
grant select, insert, update, delete on public.event_guests to authenticated;

drop policy if exists "Insiders see the guest list" on public.event_guests;
create policy "Insiders see the guest list" on public.event_guests for select to authenticated
  using (public.is_event_insider(place_id));

-- Only the host adds themselves directly; everyone else gets in with the
-- code (unlock_private_event).
drop policy if exists "Host joins own event" on public.event_guests;
create policy "Host joins own event" on public.event_guests for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

drop policy if exists "Change your own RSVP" on public.event_guests;
create policy "Change your own RSVP" on public.event_guests for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "Leave, or host removes a guest" on public.event_guests;
create policy "Leave, or host removes a guest" on public.event_guests for delete to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

-- Enter the host's code: you're in (and can RSVP). Returns the address,
-- spot and time, or an error message.
create or replace function public.unlock_private_event(p_place uuid, p_code text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  d record;
  tries integer;
begin
  if me is null or public.is_guest() then
    return jsonb_build_object('error', 'Make an account to unlock private events.');
  end if;
  select * into d from public.private_event_details where place_id = p_place;
  if not found then
    return jsonb_build_object('error', 'That event isn''t private.');
  end if;
  if not exists (select 1 from public.event_guests where place_id = p_place and user_id = me) then
    select count(*) into tries from public.event_unlock_attempts
     where user_id = me and at > now() - interval '1 hour';
    if tries >= 10 then
      return jsonb_build_object('error', 'Too many wrong codes. Try again in a bit.');
    end if;
    if lower(btrim(coalesce(p_code, ''))) <> lower(btrim(d.passcode)) then
      insert into public.event_unlock_attempts (user_id, place_id) values (me, p_place);
      delete from public.event_unlock_attempts where at < now() - interval '1 day';
      return jsonb_build_object('error', 'Wrong code. Ask the host for it.');
    end if;
    insert into public.event_guests (place_id, user_id, status) values (p_place, me, 'unlocked')
    on conflict (place_id, user_id) do nothing;
  end if;
  return jsonb_build_object('address', d.address, 'lat', d.lat, 'lng', d.lng, 'starts_at', d.starts_at);
end;
$$;

grant execute on function public.unlock_private_event(uuid, text) to authenticated;

-- ---- 3) Event chat ------------------------------------------------------------

create table if not exists public.event_messages (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  sender_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  text text not null check (char_length(text) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists event_messages_place_idx on public.event_messages (place_id, created_at);

create or replace function public.can_see_event(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select coalesce((select not is_private from public.places where id = p), false)
      or public.is_event_insider(p)
$$;

grant execute on function public.can_see_event(uuid) to authenticated;

alter table public.event_messages enable row level security;
grant select, insert, delete on public.event_messages to authenticated;

drop policy if exists "See event chat" on public.event_messages;
create policy "See event chat" on public.event_messages for select to authenticated
  using (public.can_see_event(place_id));

drop policy if exists "Talk in event chat" on public.event_messages;
create policy "Talk in event chat" on public.event_messages for insert to authenticated
  with check (sender_id = auth.uid() and not public.is_banned() and not public.is_guest() and public.can_see_event(place_id));

drop policy if exists "Delete event chat messages" on public.event_messages;
create policy "Delete event chat messages" on public.event_messages for delete to authenticated
  using (sender_id = auth.uid() or public.is_admin() or exists (select 1 from public.places where id = place_id and by_uid = auth.uid()));

drop trigger if exists rate_limit_event_messages on public.event_messages;
create trigger rate_limit_event_messages before insert on public.event_messages
  for each row execute procedure public.rate_limit('sender_id', '60', '15');

-- Tell the host when someone asks something (one notification per event).
create or replace function public.notify_event_message()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  host uuid;
  nm text;
  who text;
begin
  select by_uid, name into host, nm from public.places where id = new.place_id;
  if host is null or host = new.sender_id then
    return new;
  end if;
  who := public.notif_handle(new.sender_id);
  delete from public.notifications
   where user_id = host and kind = 'event_chat' and read_at is null and data ->> 'place_id' = new.place_id::text;
  perform public.push_notify(host, 'event_chat', coalesce(nm, 'Your event'), '@' || who || ': ' || left(new.text, 100),
    jsonb_build_object('place_id', new.place_id));
  return new;
end;
$$;

revoke all on function public.notify_event_message() from public, anon, authenticated;

drop trigger if exists event_messages_notify on public.event_messages;
create trigger event_messages_notify after insert on public.event_messages
  for each row execute function public.notify_event_message();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'event_messages'
     ) then
    alter publication supabase_realtime add table public.event_messages;
  end if;
end;
$$;
