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
