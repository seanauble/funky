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

select 'Phase 11 ready' as status;
