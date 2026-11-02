-- ============================================================
-- Phase 43: Payment cards + private events, run properly
--   1) Your payment apps (Venmo, Cash App, PayPal, Zelle, Apple Cash).
--   2) Cards in chats: a payment card ("Pay me $10") in DMs, group chats and
--      event chats, with an "I paid" button; plus the "asked to go" and
--      "you're in" cards the server sends.
--   3) Private events:
--      * one code for everyone, or a code for each person (used once)
--      * co-hosts (edit details, make codes, let people in) and door staff
--        (check people in)
--      * "Ask to go" -> the host sends their Venmo -> "Let them in"
--      * check-in at the door
--      * the host picks whether everyone sees how many are going, or only
--        the hosts (everyone else sees a few faces)
-- Safe to run more than once. Needs phases 2, 7, 11, 15, 31, 33, 34, 36, 37.
-- ============================================================

-- ---- 1) Payment apps -----------------------------------------------------------

create table if not exists public.payment_handles (
  user_id uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  venmo text,
  cashapp text,
  paypal text,
  zelle text,
  applecash text,
  updated_at timestamptz not null default now()
);

alter table public.payment_handles enable row level security;
grant select, insert, update, delete on public.payment_handles to authenticated;

drop policy if exists "Your own payment apps" on public.payment_handles;
create policy "Your own payment apps" on public.payment_handles for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and not public.is_guest());

-- A username for one payment app, cleaned up, or null if it isn't valid.
create or replace function public.clean_pay_handle(app text, v text)
returns text
language plpgsql
immutable
as $$
declare
  s text := btrim(coalesce(v, ''));
begin
  if app = 'venmo' then
    s := ltrim(s, '@');
    if s ~ '^[A-Za-z0-9_-]{1,40}$' then return s; end if;
  elsif app = 'cashapp' then
    s := ltrim(s, '$');
    if s ~ '^[A-Za-z0-9_-]{1,30}$' then return s; end if;
  elsif app = 'paypal' then
    s := regexp_replace(s, '^(https?://)?(www\.)?paypal\.me/', '', 'i');
    if s ~ '^[A-Za-z0-9]{1,40}$' then return s; end if;
  elsif app in ('zelle', 'applecash') then
    if s ~ '^[A-Za-z0-9@._+() -]{3,80}$' then return s; end if;
  end if;
  return null;
end;
$$;

create or replace function public.payment_handles_clean()
returns trigger
language plpgsql
as $$
begin
  new.venmo := public.clean_pay_handle('venmo', new.venmo);
  new.cashapp := public.clean_pay_handle('cashapp', new.cashapp);
  new.paypal := public.clean_pay_handle('paypal', new.paypal);
  new.zelle := public.clean_pay_handle('zelle', new.zelle);
  new.applecash := public.clean_pay_handle('applecash', new.applecash);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists payment_handles_clean on public.payment_handles;
create trigger payment_handles_clean before insert or update on public.payment_handles
  for each row execute function public.payment_handles_clean();

-- ---- 2) Cards in chats -----------------------------------------------------------

alter table public.messages add column if not exists card jsonb;
alter table public.group_messages add column if not exists card jsonb;
alter table public.event_messages add column if not exists card jsonb;

-- A card someone sent, cleaned up (or null if it isn't a real card).
-- Payment cards can be sent by anyone; "asked to go" and "you're in" cards
-- only by the server itself.
create or replace function public.clean_chat_card(p jsonb)
returns jsonb
language plpgsql
stable
security definer set search_path = public
as $$
declare
  t text;
  amt text;
  note text;
  apps jsonb := '{}'::jsonb;
  k text;
  v text;
  h text;
  pid uuid;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return null; end if;
  t := p ->> 'type';
  if t = 'pay' then
    amt := nullif(btrim(coalesce(p ->> 'amount', '')), '');
    if amt is not null and amt !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then amt := null; end if;
    if amt is not null and amt::numeric <= 0 then amt := null; end if;
    note := left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 80);
    if jsonb_typeof(p -> 'apps') = 'object' then
      for k, v in select key, value from jsonb_each_text(p -> 'apps') loop
        h := public.clean_pay_handle(k, v);
        if h is not null then apps := apps || jsonb_build_object(k, h); end if;
      end loop;
    end if;
    if apps = '{}'::jsonb then return null; end if;
    if coalesce(p ->> 'place_id', '') ~ '^[0-9a-fA-F-]{36}$' then
      pid := (p ->> 'place_id')::uuid;
      if not exists (select 1 from public.places where id = pid) then pid := null; end if;
    end if;
    return jsonb_strip_nulls(jsonb_build_object('type', 'pay', 'amount', amt, 'note', note, 'apps', apps, 'place_id', pid))
           || jsonb_build_object('paid', '[]'::jsonb);
  elsif t in ('ask', 'entry') then
    if coalesce(current_setting('funky.card_server', true), '') = 'on' then return p; end if;
    return null;
  end if;
  return null;
end;
$$;

revoke all on function public.clean_chat_card(jsonb) from public, anon, authenticated;

-- Cards are cleaned on the way in and can't be changed afterwards (except
-- by mark_payment_sent below).
create or replace function public.chat_card_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  cleaned jsonb;
begin
  if tg_op = 'INSERT' then
    if new.card is not null then
      cleaned := public.clean_chat_card(new.card);
      -- A card that didn't survive cleaning, with nothing else in the
      -- message, isn't a message.
      if cleaned is null and coalesce(new.text, '') = '' then
        raise exception 'That payment card isn''t valid — check your payment apps.' using errcode = '23514';
      end if;
      new.card := cleaned;
    end if;
  elsif new.card is distinct from old.card and coalesce(current_setting('funky.card_update', true), '') <> 'on' then
    new.card := old.card;
  end if;
  return new;
end;
$$;

revoke all on function public.chat_card_guard() from public, anon, authenticated;

drop trigger if exists chat_card_guard on public.messages;
create trigger chat_card_guard before insert or update on public.messages
  for each row execute function public.chat_card_guard();
drop trigger if exists chat_card_guard on public.group_messages;
create trigger chat_card_guard before insert or update on public.group_messages
  for each row execute function public.chat_card_guard();
drop trigger if exists chat_card_guard on public.event_messages;
create trigger chat_card_guard before insert or update on public.event_messages
  for each row execute function public.chat_card_guard();

-- A message can be just a card.
do $$
begin
  alter table public.group_messages drop constraint if exists group_messages_has_content;
  alter table public.group_messages add constraint group_messages_has_content
    check (char_length(text) > 0 or media_path is not null or gif_url is not null or card is not null);
  alter table public.event_messages drop constraint if exists event_messages_text_check;
  if not exists (select 1 from pg_constraint where conname = 'event_messages_text_ok') then
    alter table public.event_messages add constraint event_messages_text_ok
      check (char_length(text) <= 500 and (char_length(text) >= 1 or card is not null));
  end if;
end;
$$;

-- What a notification says for a card.
create or replace function public.card_preview(c jsonb)
returns text
language sql
immutable
as $$
  select case c ->> 'type'
    when 'pay' then '💸 Payment request' || coalesce(' · $' || (c ->> 'amount'), '') || coalesce(' · ' || (c ->> 'note'), '')
    when 'ask' then '🙋 Asked to go to ' || coalesce(c ->> 'name', 'your event')
    when 'entry' then '🎉 You''re in: ' || coalesce(c ->> 'name', 'the event')
    else null
  end
$$;

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
  if new.card is not null and coalesce(new.text, '') = '' then
    preview := coalesce(public.card_preview(new.card), 'Sent you something');
  elsif new.media_path is not null and coalesce(new.text, '') = '' then
    preview := case when new.media_type = 'video' then 'Sent you a video' else 'Sent you a photo' end;
  elsif new.gif_url is not null and coalesce(new.text, '') = '' then
    preview := 'Sent you a GIF';
  elsif new.card is not null then
    preview := left(public.card_preview(new.card) || ' — ' || new.text, 120);
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
  if new.card is not null and char_length(new.text) = 0 then
    preview := '@' || who || ': ' || coalesce(public.card_preview(new.card), 'sent something');
  elsif new.media_path is not null and char_length(new.text) = 0 then
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

create or replace function public.notify_event_message()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  host uuid;
  nm text;
  who text;
  body text;
begin
  select by_uid, name into host, nm from public.places where id = new.place_id;
  if host is null or host = new.sender_id then
    return new;
  end if;
  who := public.notif_handle(new.sender_id);
  body := case when new.card is not null and char_length(new.text) = 0
               then coalesce(public.card_preview(new.card), 'sent something')
               else left(new.text, 100) end;
  delete from public.notifications
   where user_id = host and kind = 'event_chat' and read_at is null and data ->> 'place_id' = new.place_id::text;
  perform public.push_notify(host, 'event_chat', coalesce(nm, 'Your event'), '@' || who || ': ' || body,
    jsonb_build_object('place_id', new.place_id));
  return new;
end;
$$;

-- "I paid": adds you to the card's paid list and tells whoever sent it.
-- p_kind is 'dm', 'group' or 'event'. Returns the updated card, or
-- {"error": ...}.
create or replace function public.mark_payment_sent(p_kind text, p_message uuid, p_via text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  via text := case when p_via in ('venmo', 'cashapp', 'paypal', 'zelle', 'applecash', 'cash') then p_via else 'other' end;
  sender uuid;
  c jsonb;
  allowed boolean := false;
  data jsonb;
  ev uuid;
  label text;
  who text;
begin
  if me is null or public.is_guest() then return jsonb_build_object('error', 'Make an account first.'); end if;
  if p_kind = 'dm' then
    select sender_id, card, recipient_id = me into sender, c, allowed from public.messages where id = p_message;
    data := jsonb_build_object('from', me);
  elsif p_kind = 'group' then
    select sender_id, card, public.is_group_member(group_id), jsonb_build_object('group_id', group_id)
      into sender, c, allowed, data from public.group_messages where id = p_message;
  elsif p_kind = 'event' then
    select sender_id, card, public.can_see_event(place_id), jsonb_build_object('place_id', place_id)
      into sender, c, allowed, data from public.event_messages where id = p_message;
  end if;
  if sender = me then return jsonb_build_object('error', 'That''s your own card.'); end if;
  if c is null or c ->> 'type' <> 'pay' or not coalesce(allowed, false) then
    return jsonb_build_object('error', 'That payment card isn''t around anymore.');
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(c -> 'paid', '[]'::jsonb)) x where x ->> 'uid' = me::text) then
    return c;
  end if;
  if jsonb_array_length(coalesce(c -> 'paid', '[]'::jsonb)) >= 300 then
    return jsonb_build_object('error', 'That card is full.');
  end if;
  c := jsonb_set(c, '{paid}', coalesce(c -> 'paid', '[]'::jsonb)
         || jsonb_build_array(jsonb_build_object('uid', me, 'via', via, 'at', now())));

  perform set_config('funky.card_update', 'on', true);
  if p_kind = 'dm' then
    update public.messages set card = c where id = p_message;
  elsif p_kind = 'group' then
    update public.group_messages set card = c where id = p_message;
  else
    update public.event_messages set card = c where id = p_message;
  end if;
  perform set_config('funky.card_update', 'off', true);

  -- Paying for an event you asked to go to moves your request along.
  if coalesce(c ->> 'place_id', '') <> '' then
    ev := (c ->> 'place_id')::uuid;
    update public.event_requests set status = 'paid', updated_at = now()
     where place_id = ev and user_id = me and status in ('asked', 'pay_sent');
  end if;

  label := case via when 'venmo' then 'Venmo' when 'cashapp' then 'Cash App' when 'paypal' then 'PayPal'
                    when 'zelle' then 'Zelle' when 'applecash' then 'Apple Cash' when 'cash' then 'cash' else 'another app' end;
  who := public.notif_handle(me);
  perform public.push_notify(
    sender, 'pay',
    '@' || who || ' says they paid you' || coalesce(' $' || (c ->> 'amount'), ''),
    'On ' || label || coalesce(' · ' || (c ->> 'note'), '') || '. Check ' || label || ' to make sure it came through.',
    data || jsonb_build_object('message_id', p_message));
  return c;
end;
$$;

grant execute on function public.mark_payment_sent(text, uuid, text) to authenticated;

-- ---- 3) Private events, run properly ------------------------------------------

alter table public.private_event_details add column if not exists code_mode text not null default 'shared';
alter table public.places add column if not exists entry_price numeric(7, 2);
alter table public.places add column if not exists going_visibility text not null default 'public';
alter table public.event_guests add column if not exists checked_in_at timestamptz;
alter table public.event_guests add column if not exists checked_in_by uuid;
alter table public.event_guests add column if not exists let_in_by uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'private_event_details_code_mode_ok') then
    alter table public.private_event_details add constraint private_event_details_code_mode_ok
      check (code_mode in ('shared', 'personal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'places_entry_price_ok') then
    alter table public.places add constraint places_entry_price_ok
      check (entry_price is null or (entry_price >= 0 and entry_price <= 10000));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'places_going_visibility_ok') then
    alter table public.places add constraint places_going_visibility_ok
      check (going_visibility in ('public', 'hint'));
  end if;
end;
$$;

-- Who helps run an event (the host is the place's by_uid).
create table if not exists public.event_hosts (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null check (role in ('cohost', 'door')),
  added_by uuid,
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

create index if not exists event_hosts_user_idx on public.event_hosts (user_id);

-- Your part in running an event: 'host', 'cohost', 'door', or null.
create or replace function public.event_role(p uuid)
returns text
language sql
stable
security definer set search_path = public
as $$
  select case
    when exists (select 1 from public.places where id = p and by_uid = auth.uid()) then 'host'
    when public.is_admin() then 'host'
    else (select role from public.event_hosts where place_id = p and user_id = auth.uid())
  end
$$;

grant execute on function public.event_role(uuid) to authenticated;

create or replace function public.can_manage_event(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select coalesce(public.event_role(p) in ('host', 'cohost'), false)
$$;

grant execute on function public.can_manage_event(uuid) to authenticated;

create or replace function public.is_event_staff(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select public.event_role(p) is not null
$$;

grant execute on function public.is_event_staff(uuid) to authenticated;

-- Insiders now include the co-hosts and door staff.
create or replace function public.is_event_insider(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select public.is_admin()
      or exists (select 1 from public.places where id = p and by_uid = auth.uid())
      or exists (select 1 from public.event_guests where place_id = p and user_id = auth.uid())
      or exists (select 1 from public.event_hosts where place_id = p and user_id = auth.uid())
$$;

alter table public.event_hosts enable row level security;
grant select on public.event_hosts to authenticated;

drop policy if exists "Insiders see who runs it" on public.event_hosts;
create policy "Insiders see who runs it" on public.event_hosts for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_event_insider(place_id)
    or coalesce((select not is_private from public.places where id = place_id), false)
  );

-- Co-hosts can change the private details too.
drop policy if exists "Host changes private details" on public.private_event_details;
create policy "Host changes private details" on public.private_event_details for update to authenticated
  using (public.can_manage_event(place_id))
  with check (public.can_manage_event(place_id));

-- The guest list: hosts always; guests see everyone only when the host
-- shows the count (otherwise just themselves — the app shows a few faces).
drop policy if exists "Insiders see the guest list" on public.event_guests;
drop policy if exists "See the guest list" on public.event_guests;
create policy "See the guest list" on public.event_guests for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_event_staff(place_id)
    or (public.is_event_insider(place_id)
        and coalesce((select going_visibility from public.places where id = place_id), 'public') = 'public')
  );

drop policy if exists "Host joins own event" on public.event_guests;
create policy "Host joins own event" on public.event_guests for insert to authenticated
  with check (user_id = auth.uid() and public.is_event_staff(place_id));

drop policy if exists "Leave, or host removes a guest" on public.event_guests;
create policy "Leave, or host removes a guest" on public.event_guests for delete to authenticated
  using (user_id = auth.uid() or public.can_manage_event(place_id));

-- Guests can change their RSVP, not their check-in.
create or replace function public.event_guests_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if coalesce(current_setting('funky.guest_staff', true), '') <> 'on' then
    if tg_op = 'INSERT' then
      new.checked_in_at := null;
      new.checked_in_by := null;
      if new.let_in_by is not null and new.let_in_by <> auth.uid() then new.let_in_by := null; end if;
    else
      new.checked_in_at := old.checked_in_at;
      new.checked_in_by := old.checked_in_by;
      new.let_in_by := old.let_in_by;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.event_guests_guard() from public, anon, authenticated;

drop trigger if exists event_guests_guard on public.event_guests;
create trigger event_guests_guard before insert or update on public.event_guests
  for each row execute function public.event_guests_guard();

-- Event chat: co-hosts can take messages down too.
drop policy if exists "Delete event chat messages" on public.event_messages;
create policy "Delete event chat messages" on public.event_messages for delete to authenticated
  using (sender_id = auth.uid() or public.can_manage_event(place_id));

-- ---- Codes for each person ----------------------------------------------------

create table if not exists public.event_codes (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9]{6,10}$'),
  label text check (label is null or char_length(label) <= 40),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  used_by uuid references public.profiles (id) on delete set null,
  used_at timestamptz
);

create index if not exists event_codes_place_idx on public.event_codes (place_id, created_at);

alter table public.event_codes enable row level security;
grant select on public.event_codes to authenticated;

drop policy if exists "Hosts see the codes" on public.event_codes;
create policy "Hosts see the codes" on public.event_codes for select to authenticated
  using (public.can_manage_event(place_id) or used_by = auth.uid());

-- Make codes (each works once). Returns [{"id","code","label"}] or {"error"}.
create or replace function public.make_event_codes(p_place uuid, p_count integer, p_label text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  n integer := greatest(1, least(coalesce(p_count, 1), 100));
  lbl text := left(nullif(btrim(coalesce(p_label, '')), ''), 40);
  made jsonb := '[]'::jsonb;
  c text;
  new_id uuid;
  tries integer;
begin
  if not public.can_manage_event(p_place) then
    return jsonb_build_object('error', 'Only the host and co-hosts can make codes.');
  end if;
  if not exists (select 1 from public.private_event_details where place_id = p_place) then
    return jsonb_build_object('error', 'Codes are for private events.');
  end if;
  if (select count(*) from public.event_codes where place_id = p_place) + n > 1000 then
    return jsonb_build_object('error', 'That''s the most codes one event can have.');
  end if;
  for i in 1 .. n loop
    tries := 0;
    loop
      tries := tries + 1;
      c := '';
      for j in 1 .. 7 loop
        c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::integer, 1);
      end loop;
      begin
        insert into public.event_codes (place_id, code, label, created_by)
        values (p_place, c, case when n = 1 then lbl else coalesce(lbl || ' ' || i, null) end, auth.uid())
        returning id into new_id;
        exit;
      exception when unique_violation then
        if tries > 20 then raise; end if;
      end;
    end loop;
    made := made || jsonb_build_array(jsonb_build_object('id', new_id, 'code', c,
              'label', case when n = 1 then lbl else coalesce(lbl || ' ' || i, null) end));
  end loop;
  return made;
end;
$$;

grant execute on function public.make_event_codes(uuid, integer, text) to authenticated;

-- Delete a code nobody used yet. Returns 'ok' or an error starting with '!'.
create or replace function public.delete_event_code(p_code uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  c public.event_codes;
begin
  select * into c from public.event_codes where id = p_code;
  if not found then return 'ok'; end if;
  if not public.can_manage_event(c.place_id) then return '!Only the host and co-hosts can do that.'; end if;
  if c.used_by is not null then return '!Someone already used it — take them off the guest list instead.'; end if;
  delete from public.event_codes where id = p_code;
  return 'ok';
end;
$$;

grant execute on function public.delete_event_code(uuid) to authenticated;

-- Enter a code on the event's page: a personal code (used once), or the
-- shared code when the host uses one. Returns the details or {"error"}.
create or replace function public.unlock_private_event(p_place uuid, p_code text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  d record;
  c public.event_codes;
  tries integer;
  typed text := btrim(coalesce(p_code, ''));
begin
  if me is null or public.is_guest() then
    return jsonb_build_object('error', 'Make an account to unlock private events.');
  end if;
  select * into d from public.private_event_details where place_id = p_place;
  if not found then
    return jsonb_build_object('error', 'That event isn''t private.');
  end if;
  if not public.is_event_insider(p_place) then
    select count(*) into tries from public.event_unlock_attempts
     where user_id = me and at > now() - interval '1 hour';
    if tries >= 10 then
      return jsonb_build_object('error', 'Too many wrong codes. Try again in a bit.');
    end if;
    select * into c from public.event_codes where place_id = p_place and code = upper(typed) for update;
    if found and c.used_by is null then
      update public.event_codes set used_by = me, used_at = now() where id = c.id;
      perform set_config('funky.guest_staff', 'on', true);
      insert into public.event_guests (place_id, user_id, status, let_in_by)
      values (p_place, me, 'going', c.created_by)
      on conflict (place_id, user_id) do nothing;
      perform set_config('funky.guest_staff', 'off', true);
      update public.event_requests set status = 'in', updated_at = now() where place_id = p_place and user_id = me;
    elsif found then
      insert into public.event_unlock_attempts (user_id, place_id) values (me, p_place);
      return jsonb_build_object('error', 'That code was already used. Each code works once — ask the host for your own.');
    elsif d.code_mode = 'shared' and lower(typed) = lower(btrim(d.passcode)) then
      insert into public.event_guests (place_id, user_id, status) values (p_place, me, 'unlocked')
      on conflict (place_id, user_id) do nothing;
    else
      insert into public.event_unlock_attempts (user_id, place_id) values (me, p_place);
      delete from public.event_unlock_attempts where at < now() - interval '1 day';
      return jsonb_build_object('error', 'Wrong code. Ask the host for it.');
    end if;
  end if;
  return jsonb_build_object('address', d.address, 'lat', d.lat, 'lng', d.lng, 'starts_at', d.starts_at);
end;
$$;

grant execute on function public.unlock_private_event(uuid, text) to authenticated;

-- "Have a code?" anywhere in the app: finds the event the code is for and
-- lets you in. Returns {"place_id", "name"} or {"error"}.
create or replace function public.join_with_code(p_code text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  typed text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  c public.event_codes;
  tries integer;
  res jsonb;
begin
  if me is null or public.is_guest() then
    return jsonb_build_object('error', 'Make an account to use a code.');
  end if;
  select count(*) into tries from public.event_unlock_attempts where user_id = me and at > now() - interval '1 hour';
  if tries >= 10 then
    return jsonb_build_object('error', 'Too many wrong codes. Try again in a bit.');
  end if;
  select * into c from public.event_codes where code = typed;
  if not found then
    insert into public.event_unlock_attempts (user_id, place_id) values (me, '00000000-0000-0000-0000-000000000000');
    return jsonb_build_object('error', 'No event has that code. Check it, or open the event and enter it there.');
  end if;
  res := public.unlock_private_event(c.place_id, typed);
  if res ? 'error' then return res; end if;
  return jsonb_build_object('place_id', c.place_id, 'name', (select name from public.places where id = c.place_id));
end;
$$;

grant execute on function public.join_with_code(text) to authenticated;

-- ---- Asking to go -----------------------------------------------------------------

create table if not exists public.event_requests (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'asked' check (status in ('asked', 'pay_sent', 'paid', 'in', 'declined')),
  note text check (note is null or char_length(note) <= 200),
  handled_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

create index if not exists event_requests_place_idx on public.event_requests (place_id, updated_at desc);

alter table public.event_requests enable row level security;
grant select on public.event_requests to authenticated;

drop policy if exists "See your requests, hosts see theirs" on public.event_requests;
create policy "See your requests, hosts see theirs" on public.event_requests for select to authenticated
  using (user_id = auth.uid() or public.can_manage_event(place_id));

-- Ask to go to a private event. Starts a chat with the host (with an
-- "asked to go" card) and lets the co-hosts know. Returns {"status",
-- "host"} or {"error"}.
create or replace function public.ask_to_join(p_place uuid, p_note text)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  pl record;
  existing text;
  who text;
  h record;
  note text := left(nullif(btrim(coalesce(p_note, '')), ''), 200);
begin
  if me is null or public.is_guest() then return jsonb_build_object('error', 'Make an account to ask.'); end if;
  if public.is_banned() then return jsonb_build_object('error', 'You can''t do that right now.'); end if;
  select id, name, by_uid, coalesce(is_private, false) as is_private into pl from public.places where id = p_place;
  if not found then return jsonb_build_object('error', 'That event isn''t around anymore.'); end if;
  if not pl.is_private then return jsonb_build_object('error', 'Anyone can go to this one — just show up.'); end if;
  if pl.by_uid = me or public.is_event_insider(p_place) then
    return jsonb_build_object('error', 'You''re already in.');
  end if;
  select status into existing from public.event_requests where place_id = p_place and user_id = me;
  if existing in ('asked', 'pay_sent', 'paid') then
    return jsonb_build_object('status', existing, 'host', pl.by_uid);
  end if;
  if existing = 'declined' then
    return jsonb_build_object('error', 'The host can''t fit you in this time.');
  end if;
  if (select count(*) from public.event_requests where user_id = me and created_at > now() - interval '1 day') >= 20 then
    return jsonb_build_object('error', 'That''s a lot of asks today. Try again tomorrow.');
  end if;
  begin
    insert into public.event_requests (place_id, user_id, note) values (p_place, me, note)
    on conflict (place_id, user_id) do update set status = 'asked', note = excluded.note, updated_at = now();
    perform set_config('funky.card_server', 'on', true);
    insert into public.messages (sender_id, recipient_id, text, card)
    values (me, pl.by_uid, coalesce(note, ''), jsonb_build_object('type', 'ask', 'place_id', p_place, 'name', pl.name));
    perform set_config('funky.card_server', 'off', true);
  exception when others then
    perform set_config('funky.card_server', 'off', true);
    return jsonb_build_object('error', 'You can''t message this host.');
  end;
  who := public.notif_handle(me);
  for h in select user_id from public.event_hosts where place_id = p_place and role = 'cohost' and user_id <> me loop
    perform public.push_notify(h.user_id, 'event_request', '@' || who || ' asked to go',
      coalesce(pl.name, 'Your event') || ' · see Requests to let them in.',
      jsonb_build_object('place_id', p_place, 'from', me));
  end loop;
  return jsonb_build_object('status', 'asked', 'host', pl.by_uid);
end;
$$;

grant execute on function public.ask_to_join(uuid, text) to authenticated;

-- Host / co-host: send someone who asked your payment card (your payment
-- apps, the event's price). Returns 'ok' or an error starting with '!'.
create or replace function public.send_event_pay_card(p_place uuid, p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  ph public.payment_handles;
  pl record;
  apps jsonb;
begin
  if not public.can_manage_event(p_place) then return '!Only the host and co-hosts can do that.'; end if;
  select * into ph from public.payment_handles where user_id = me;
  apps := jsonb_strip_nulls(jsonb_build_object('venmo', ph.venmo, 'cashapp', ph.cashapp, 'paypal', ph.paypal,
                                               'zelle', ph.zelle, 'applecash', ph.applecash));
  if apps is null or apps = '{}'::jsonb then return '!Add your Venmo or Cash App first (Settings → Payment apps).'; end if;
  select name, entry_price into pl from public.places where id = p_place;
  begin
    insert into public.messages (sender_id, recipient_id, text, card)
    values (me, p_user, '', jsonb_build_object('type', 'pay', 'amount', pl.entry_price::text, 'note', pl.name,
                                                'apps', apps, 'place_id', p_place));
  exception when others then
    return '!Couldn''t message them.';
  end;
  update public.event_requests set status = 'pay_sent', handled_by = me, updated_at = now()
   where place_id = p_place and user_id = p_user and status = 'asked';
  return 'ok';
end;
$$;

grant execute on function public.send_event_pay_card(uuid, uuid) to authenticated;

-- Host / co-host: let someone in. They're on the list right away and get
-- a "you're in" card in their messages. Returns 'ok' or '!error'.
create or replace function public.let_into_event(p_place uuid, p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  nm text;
begin
  if not public.can_manage_event(p_place) then return '!Only the host and co-hosts can let people in.'; end if;
  if p_user is null or p_user = me then return '!Pick someone.'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return '!That account is gone.'; end if;
  select name into nm from public.places where id = p_place;
  perform set_config('funky.guest_staff', 'on', true);
  insert into public.event_guests (place_id, user_id, status, let_in_by) values (p_place, p_user, 'going', me)
  on conflict (place_id, user_id) do update set status = 'going', let_in_by = coalesce(public.event_guests.let_in_by, me);
  perform set_config('funky.guest_staff', 'off', true);
  insert into public.event_requests (place_id, user_id, status, handled_by)
  values (p_place, p_user, 'in', me)
  on conflict (place_id, user_id) do update set status = 'in', handled_by = me, updated_at = now();
  begin
    perform set_config('funky.card_server', 'on', true);
    insert into public.messages (sender_id, recipient_id, text, card)
    values (me, p_user, '', jsonb_build_object('type', 'entry', 'place_id', p_place, 'name', nm));
    perform set_config('funky.card_server', 'off', true);
  exception when others then
    perform set_config('funky.card_server', 'off', true);
    perform public.push_notify(p_user, 'invite', 'You''re in 🎉', coalesce(nm, 'The event') || ' · tap for the address and time.',
      jsonb_build_object('place_id', p_place, 'from', me));
  end;
  return 'ok';
end;
$$;

grant execute on function public.let_into_event(uuid, uuid) to authenticated;

-- Host / co-host: say no to a request.
create or replace function public.decline_event_request(p_place uuid, p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  nm text;
begin
  if not public.can_manage_event(p_place) then return '!Only the host and co-hosts can do that.'; end if;
  update public.event_requests set status = 'declined', handled_by = auth.uid(), updated_at = now()
   where place_id = p_place and user_id = p_user and status <> 'in';
  if found then
    select name into nm from public.places where id = p_place;
    perform public.push_notify(p_user, 'event_request', 'The host can''t fit you in',
      coalesce(nm, 'That event') || ' is full for now.', jsonb_build_object('place_id', p_place));
  end if;
  return 'ok';
end;
$$;

grant execute on function public.decline_event_request(uuid, uuid) to authenticated;

-- ---- Running the door ---------------------------------------------------------------

-- Staff: check someone in (or undo it). Returns {"at"} or {"already", "at"}
-- or {"error"}.
create or replace function public.check_in_guest(p_place uuid, p_user uuid, p_undo boolean)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  g public.event_guests;
begin
  if not public.is_event_staff(p_place) then return jsonb_build_object('error', 'Only the event''s team can check people in.'); end if;
  select * into g from public.event_guests where place_id = p_place and user_id = p_user for update;
  if not found then return jsonb_build_object('error', 'They''re not on the list.'); end if;
  if g.status = 'cant' then return jsonb_build_object('error', 'They said they can''t make it — let them in first.'); end if;
  perform set_config('funky.guest_staff', 'on', true);
  if coalesce(p_undo, false) then
    update public.event_guests set checked_in_at = null, checked_in_by = null where place_id = p_place and user_id = p_user;
    perform set_config('funky.guest_staff', 'off', true);
    return jsonb_build_object('at', null);
  end if;
  if g.checked_in_at is not null then
    perform set_config('funky.guest_staff', 'off', true);
    return jsonb_build_object('already', true, 'at', g.checked_in_at);
  end if;
  update public.event_guests set checked_in_at = now(), checked_in_by = auth.uid(), status = 'going'
   where place_id = p_place and user_id = p_user;
  perform set_config('funky.guest_staff', 'off', true);
  return jsonb_build_object('at', now());
end;
$$;

grant execute on function public.check_in_guest(uuid, uuid, boolean) to authenticated;

-- Host: make someone a co-host or door staff (or take it away with null).
create or replace function public.set_event_role(p_place uuid, p_user uuid, p_role text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  pl record;
begin
  select id, name, by_uid into pl from public.places where id = p_place;
  if not found then return '!That event isn''t around anymore.'; end if;
  if pl.by_uid is distinct from auth.uid() and not public.is_admin() then return '!Only the host can change the team.'; end if;
  if p_user = pl.by_uid then return '!That''s the host.'; end if;
  if p_role is null or p_role = '' then
    delete from public.event_hosts where place_id = p_place and user_id = p_user;
    return 'ok';
  end if;
  if p_role not in ('cohost', 'door') then return '!Pick co-host or door.'; end if;
  if not exists (select 1 from public.profiles where id = p_user and not coalesce(banned, false)) then
    return '!That account can''t help run events.';
  end if;
  if not exists (select 1 from public.event_hosts where place_id = p_place and user_id = p_user)
     and (select count(*) from public.event_hosts where place_id = p_place) >= 25 then
    return '!That''s a big team already (25).';
  end if;
  insert into public.event_hosts (place_id, user_id, role, added_by) values (p_place, p_user, p_role, auth.uid())
  on conflict (place_id, user_id) do update set role = excluded.role;
  perform public.push_notify(
    p_user, 'event_role',
    case when p_role = 'cohost' then 'You''re a co-host for ' else 'You''re working the door for ' end || coalesce(pl.name, 'an event'),
    case when p_role = 'cohost' then 'You can change the details, make codes and let people in.'
         else 'Open the event and tap Door to check people in.' end,
    jsonb_build_object('place_id', p_place));
  return 'ok';
end;
$$;

grant execute on function public.set_event_role(uuid, uuid, text) to authenticated;

-- Host / co-host: change an event. Any key left out stays the same.
-- Keys: name, starts_at, public_starts_at, address, lat, lng, price,
-- going_visibility, code_mode, passcode. Returns 'ok' or '!error'.
create or replace function public.update_event(p_place uuid, p jsonb)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  pl record;
  d record;
  nm text;
  price numeric;
  vis text;
  mode text;
  code text;
begin
  if not public.can_manage_event(p_place) then return '!Only the host and co-hosts can change this.'; end if;
  select id, coalesce(is_private, false) as is_private into pl from public.places where id = p_place;
  if not found then return '!That event isn''t around anymore.'; end if;

  if p ? 'name' then
    nm := left(btrim(coalesce(p ->> 'name', '')), 60);
    if nm = '' then return '!Give it a name.'; end if;
    update public.places set name = nm where id = p_place;
  end if;
  if p ? 'price' then
    if coalesce(p ->> 'price', '') = '' then
      price := null;
    elsif (p ->> 'price') ~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then
      price := (p ->> 'price')::numeric;
    else
      return '!That price doesn''t look right.';
    end if;
    update public.places set entry_price = case when price = 0 then null else price end where id = p_place;
  end if;
  if p ? 'going_visibility' then
    vis := p ->> 'going_visibility';
    if vis not in ('public', 'hint') then return '!Pick who sees the count.'; end if;
    update public.places set going_visibility = vis where id = p_place;
  end if;

  if pl.is_private then
    select * into d from public.private_event_details where place_id = p_place;
    if p ? 'address' then
      update public.private_event_details set address = left(btrim(coalesce(p ->> 'address', '')), 120) where place_id = p_place;
    end if;
    if p ? 'lat' and p ? 'lng' and jsonb_typeof(p -> 'lat') = 'number' and jsonb_typeof(p -> 'lng') = 'number' then
      update public.private_event_details set lat = (p ->> 'lat')::double precision, lng = (p ->> 'lng')::double precision
       where place_id = p_place;
      update public.places
         set lat = round((p ->> 'lat')::numeric, 2)::double precision, lng = round((p ->> 'lng')::numeric, 2)::double precision
       where id = p_place;
    end if;
    if p ? 'starts_at' and coalesce(p ->> 'starts_at', '') <> '' then
      update public.private_event_details set starts_at = (p ->> 'starts_at')::timestamptz where place_id = p_place;
      update public.places set starts_at = nullif(p ->> 'public_starts_at', '')::timestamptz where id = p_place;
    end if;
    if p ? 'code_mode' then
      mode := p ->> 'code_mode';
      if mode not in ('shared', 'personal') then return '!Pick how people get in.'; end if;
      if mode = 'personal' then
        -- The old shared code stops working; everyone already in stays in.
        update public.private_event_details
           set code_mode = 'personal', passcode = substr(md5(random()::text || clock_timestamp()::text), 1, 16)
         where place_id = p_place;
      else
        code := btrim(coalesce(p ->> 'passcode', ''));
        if char_length(code) < 3 or char_length(code) > 20 then return '!Pick a code (3 to 20 letters or numbers).'; end if;
        update public.private_event_details set code_mode = 'shared', passcode = code where place_id = p_place;
      end if;
    elsif p ? 'passcode' then
      code := btrim(coalesce(p ->> 'passcode', ''));
      if char_length(code) < 3 or char_length(code) > 20 then return '!Pick a code (3 to 20 letters or numbers).'; end if;
      update public.private_event_details set passcode = code where place_id = p_place and code_mode = 'shared';
    end if;
  else
    if p ? 'address' then
      update public.places set address = left(btrim(coalesce(p ->> 'address', '')), 120) where id = p_place;
    end if;
    if p ? 'lat' and p ? 'lng' and jsonb_typeof(p -> 'lat') = 'number' and jsonb_typeof(p -> 'lng') = 'number' then
      update public.places set lat = (p ->> 'lat')::double precision, lng = (p ->> 'lng')::double precision where id = p_place;
    end if;
    if p ? 'starts_at' and coalesce(p ->> 'starts_at', '') <> '' then
      update public.places set starts_at = (p ->> 'starts_at')::timestamptz where id = p_place;
    end if;
  end if;
  return 'ok';
end;
$$;

grant execute on function public.update_event(uuid, jsonb) to authenticated;

-- Who's going, the way the host wants it shown. Hosts always get the exact
-- count; with 'hint' everyone else gets a few faces (friends first) and
-- no number. People outside a private event only see friends' faces.
-- Returns {"count" (or null), "faces": [uid…], "more": bool, "hidden": bool}.
create or replace function public.event_going_preview(p_place uuid)
returns jsonb
language plpgsql
stable
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  pl record;
  staff boolean;
  insider boolean;
  total integer;
  faces uuid[];
begin
  select id, coalesce(is_private, false) as is_private, going_visibility into pl from public.places where id = p_place;
  if not found or not pl.is_private then return null; end if;
  staff := public.is_event_staff(p_place);
  insider := public.is_event_insider(p_place);
  select count(*) into total from public.event_guests where place_id = p_place and status = 'going';
  select array_agg(user_id) into faces from (
    select g.user_id
      from public.event_guests g
     where g.place_id = p_place and g.status = 'going' and g.user_id <> coalesce(me, '00000000-0000-0000-0000-000000000000'::uuid)
       and (insider or public.are_friends(me, g.user_id))
       and not exists (select 1 from public.blocks b
                        where (b.blocker_id = me and b.blocked_id = g.user_id) or (b.blocker_id = g.user_id and b.blocked_id = me))
     order by public.are_friends(me, g.user_id) desc, g.updated_at desc
     limit 5
  ) x;
  return jsonb_build_object(
    'count', case when staff or pl.going_visibility = 'public' then total end,
    'faces', to_jsonb(coalesce(faces, '{}'::uuid[])),
    'more', total > coalesce(array_length(faces, 1), 0) + (case when exists (
              select 1 from public.event_guests where place_id = p_place and user_id = me and status = 'going') then 1 else 0 end),
    'hidden', pl.going_visibility = 'hint' and not staff
  );
end;
$$;

grant execute on function public.event_going_preview(uuid) to authenticated;

-- Co-hosts can invite friends to a private event too.
create or replace function public.invite_to_place(p_place uuid, p_to uuid[])
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  pl record;
  who text;
  t uuid;
  sent integer := 0;
  n integer;
begin
  if me is null or public.is_guest() then
    return jsonb_build_object('error', 'Make an account to invite friends.');
  end if;
  if public.is_banned() then
    return jsonb_build_object('error', 'You can''t send invites right now.');
  end if;
  select id, name, by_uid, coalesce(is_private, false) as is_private into pl from public.places where id = p_place;
  if not found then
    return jsonb_build_object('error', 'That place isn''t around anymore.');
  end if;
  if pl.is_private and not public.can_manage_event(p_place) then
    return jsonb_build_object('error', 'Only the host and co-hosts can invite people to a private event.');
  end if;
  if coalesce(array_length(p_to, 1), 0) = 0 then
    return jsonb_build_object('sent', 0);
  end if;
  if array_length(p_to, 1) > 50 then
    return jsonb_build_object('error', 'You can invite up to 50 friends at a time.');
  end if;
  select count(*) into n from public.place_invites where from_uid = me and created_at > now() - interval '1 day';
  if n >= 200 then
    return jsonb_build_object('error', 'That''s a lot of invites today. Try again tomorrow.');
  end if;
  select handle into who from public.profiles where id = me;
  for t in select distinct x from unnest(p_to) as x loop
    continue when t is null or t = me or not public.are_friends(me, t);
    continue when exists (
      select 1 from public.blocks where (blocker_id = me and blocked_id = t) or (blocker_id = t and blocked_id = me)
    );
    insert into public.place_invites (place_id, from_uid, to_uid) values (p_place, me, t)
    on conflict (place_id, from_uid, to_uid) do nothing;
    if found then
      sent := sent + 1;
      if pl.is_private then
        insert into public.event_guests (place_id, user_id, status) values (p_place, t, 'unlocked')
        on conflict (place_id, user_id) do nothing;
      end if;
      perform public.push_notify(
        t, 'invite',
        '@' || coalesce(who, 'someone') || ' invited you' || case when pl.is_private then ' to a private event' else '' end,
        coalesce(pl.name, 'Tap to see where'),
        jsonb_build_object('place_id', p_place, 'from', me));
    end if;
  end loop;
  return jsonb_build_object('sent', sent);
end;
$$;

grant execute on function public.invite_to_place(uuid, uuid[]) to authenticated;

-- Live updates: group cards change when someone pays; the team and the
-- requests list change as people are let in.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['event_requests', 'event_hosts'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;
