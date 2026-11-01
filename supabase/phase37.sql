-- ============================================================
-- Phase 37:
--   1) Places been = places you posted a Story at. Tapping "I'm going"
--      doesn't count anymore. Each visit keeps the place's name, so the
--      list on your profile stays even after a party is over.
--   2) places_been(user): the "places been" flex on profiles. Friends
--      (and you) see the list; everyone else just sees how many.
--   3) Invites: invite friends to a place or party you're going to, or to
--      your private event (an invite to a private event lets them in
--      without the code). They get a notification.
-- Safe to run more than once. Needs phases 11, 27, 31, 36.
-- ============================================================

-- ---- 1) Story-only visits ------------------------------------------------

drop trigger if exists profiles_record_going_visit on public.profiles;

alter table public.place_visits add column if not exists place_name text;
alter table public.place_visits add column if not exists place_kind text;

delete from public.place_visits where via = 'going';

create or replace function public.record_story_visit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  nm text;
  kd text;
begin
  if new.place_id is not null and new.place_id <> 'main' then
    select name, kind into nm, kd from public.places where id::text = lower(new.place_id);
    insert into public.place_visits (user_id, place_id, night, via, created_at, place_name, place_kind)
    values (new.uid, lower(new.place_id), public.funky_night(new.created_at), 'story', new.created_at, nm, kd)
    on conflict (user_id, place_id, night) do update
      set via = 'story',
          place_name = coalesce(public.place_visits.place_name, excluded.place_name),
          place_kind = coalesce(public.place_visits.place_kind, excluded.place_kind);
  end if;
  return new;
end;
$$;

revoke all on function public.record_story_visit() from public, anon, authenticated;

drop trigger if exists stories_record_visit on public.stories;
create trigger stories_record_visit
  after insert on public.stories
  for each row execute function public.record_story_visit();

-- Back-fill from Stories still on the server.
insert into public.place_visits (user_id, place_id, night, via, created_at)
select s.uid, lower(s.place_id), public.funky_night(s.created_at), 'story', min(s.created_at)
  from public.stories s
 where s.place_id is not null and s.place_id <> 'main'
   and exists (select 1 from auth.users u where u.id = s.uid)
 group by s.uid, lower(s.place_id), public.funky_night(s.created_at)
on conflict (user_id, place_id, night) do nothing;

update public.place_visits v
   set place_name = p.name, place_kind = p.kind
  from public.places p
 where v.place_name is null and p.id::text = v.place_id;

-- ---- 2) The profile flex -------------------------------------------------

create or replace function public.places_been(p_user uuid)
returns jsonb
language plpgsql
stable
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  total integer;
  nights integer;
  can_see boolean;
begin
  if me is null or p_user is null then
    return jsonb_build_object('count', 0, 'nights', 0, 'places', null);
  end if;
  if exists (
    select 1 from public.blocks
     where (blocker_id = me and blocked_id = p_user) or (blocker_id = p_user and blocked_id = me)
  ) then
    return jsonb_build_object('count', 0, 'nights', 0, 'places', null);
  end if;
  select count(distinct place_id), count(*) into total, nights
    from public.place_visits where user_id = p_user;
  can_see := p_user = me or public.is_admin() or public.are_friends(me, p_user);
  return jsonb_build_object(
    'count', coalesce(total, 0),
    'nights', coalesce(nights, 0),
    'places', case when can_see then (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.place_id, 'name', x.name, 'kind', x.kind, 'nights', x.n, 'last', x.last)
                                order by x.n desc, x.last desc), '[]'::jsonb)
        from (
          select place_id, max(place_name) as name, max(place_kind) as kind, count(*) as n, max(night) as last
            from public.place_visits
           where user_id = p_user
           group by place_id
           limit 200
        ) x
    ) else null end
  );
end;
$$;

grant execute on function public.places_been(uuid) to authenticated;

-- ---- 3) Invites ------------------------------------------------------------

create table if not exists public.place_invites (
  place_id uuid not null references public.places (id) on delete cascade,
  from_uid uuid not null references auth.users (id) on delete cascade,
  to_uid uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (place_id, from_uid, to_uid)
);

create index if not exists place_invites_to_idx on public.place_invites (to_uid, created_at desc);
create index if not exists place_invites_from_idx on public.place_invites (from_uid, created_at desc);

alter table public.place_invites enable row level security;
grant select, delete on public.place_invites to authenticated;

drop policy if exists "See invites you sent or got" on public.place_invites;
create policy "See invites you sent or got" on public.place_invites for select to authenticated
  using (from_uid = auth.uid() or to_uid = auth.uid());

drop policy if exists "Dismiss or take back an invite" on public.place_invites;
create policy "Dismiss or take back an invite" on public.place_invites for delete to authenticated
  using (from_uid = auth.uid() or to_uid = auth.uid());

-- Invite friends (up to 50 at a time). Returns {"sent": n} or {"error": ...}.
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
  if pl.is_private and pl.by_uid is distinct from me and not public.is_admin() then
    return jsonb_build_object('error', 'Only the host can invite people to a private event.');
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
