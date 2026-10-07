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

select 'Phase 13 ready' as status;
