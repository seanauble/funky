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

select 'Phase 14 ready' as status;
