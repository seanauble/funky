-- ============================================================
-- Phase 27: "You've been here." Every night you tap "I'm going" on a
-- place, or post a Story there, is remembered, so the app can put a
-- been-here badge next to places you've been. Only you can see your own.
-- Filled in automatically by the database (works for older app versions
-- too), plus a one-time back-fill from your past Stories.
-- Safe to run more than once.
-- ============================================================

create table if not exists public.place_visits (
  user_id uuid not null references auth.users (id) on delete cascade,
  place_id text not null,
  -- The FUNKY "night" (it rolls over at 2 PM Eastern).
  night date not null,
  via text not null default 'going' check (via in ('going', 'story')),
  created_at timestamptz not null default now(),
  primary key (user_id, place_id, night)
);

create index if not exists place_visits_user_idx on public.place_visits (user_id);

alter table public.place_visits enable row level security;
grant select on public.place_visits to authenticated;

drop policy if exists "See your own place visits" on public.place_visits;
create policy "See your own place visits"
  on public.place_visits for select to authenticated
  using (user_id = auth.uid());

create or replace function public.funky_night(ts timestamptz)
returns date
language sql
stable
as $$
  select ((ts at time zone 'America/New_York') - interval '14 hours')::date
$$;

create or replace function public.try_date(t text)
returns date
language plpgsql
immutable
as $$
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return t::date;
exception when others then
  return null;
end;
$$;

-- A Story posted at a place.
create or replace function public.record_story_visit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.place_id is not null and new.place_id <> 'main' then
    insert into public.place_visits (user_id, place_id, night, via, created_at)
    values (new.uid, lower(new.place_id), public.funky_night(new.created_at), 'story', new.created_at)
    on conflict (user_id, place_id, night) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_record_visit on public.stories;
create trigger stories_record_visit
  after insert on public.stories
  for each row execute function public.record_story_visit();

-- "I'm going" on a place (profiles.move holds tonight's pick).
create or replace function public.record_going_visit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  n date;
begin
  if new.move is not null and new.move <> 'in' and new.move <> ''
     and (tg_op = 'INSERT'
          or new.move is distinct from old.move
          or new.move_session is distinct from old.move_session) then
    n := coalesce(public.try_date(new.move_session), public.funky_night(now()));
    insert into public.place_visits (user_id, place_id, night, via)
    values (new.id, lower(new.move), n, 'going')
    on conflict (user_id, place_id, night) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_record_going_visit on public.profiles;
create trigger profiles_record_going_visit
  after insert or update of move, move_session on public.profiles
  for each row execute function public.record_going_visit();

-- Back-fill from Stories already posted at places, and tonight's picks.
insert into public.place_visits (user_id, place_id, night, via, created_at)
select s.uid, lower(s.place_id), public.funky_night(s.created_at), 'story', min(s.created_at)
  from public.stories s
 where s.place_id is not null and s.place_id <> 'main'
 group by s.uid, lower(s.place_id), public.funky_night(s.created_at)
on conflict (user_id, place_id, night) do nothing;

insert into public.place_visits (user_id, place_id, night, via)
select p.id, lower(p.move), public.try_date(p.move_session), 'going'
  from public.profiles p
 where p.move is not null and p.move <> 'in' and p.move <> ''
   and public.try_date(p.move_session) is not null
   and exists (select 1 from auth.users u where u.id = p.id)
on conflict (user_id, place_id, night) do nothing;
