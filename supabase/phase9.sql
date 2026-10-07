-- ============================================================
-- PHASE 9 — Star ratings for places (0.5 to 5 stars, half stars OK).
-- One rating per person per place, and you can only rate a given place
-- once every 30 days (removing your rating doesn't reset that clock).
-- Safe to re-run.
-- ============================================================

create table if not exists public.place_ratings (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  stars numeric(2,1) not null check (stars >= 0.5 and stars <= 5 and (stars * 2) = floor(stars * 2)),
  created_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

-- Remembers WHEN you last rated each place, so removing a rating can't be
-- used to dodge the once-a-month limit. Only the rating functions touch it.
create table if not exists public.place_rating_log (
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  rated_at timestamptz not null default now(),
  primary key (place_id, user_id)
);

alter table public.place_ratings enable row level security;
alter table public.place_rating_log enable row level security;

drop policy if exists "See place ratings" on public.place_ratings;
create policy "See place ratings"
  on public.place_ratings for select to authenticated using (true);

drop policy if exists "See own rating log" on public.place_rating_log;
create policy "See own rating log"
  on public.place_rating_log for select to authenticated using (auth.uid() = user_id);

-- No insert/update/delete policies on purpose: everything goes through
-- rate_place / remove_my_rating below.

-- Rate (or re-rate) a place. Returns null when it worked, otherwise a
-- short message to show the person.
create or replace function public.rate_place(p_place uuid, p_stars numeric)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  last_at timestamptz;
begin
  if uid is null then return 'Sign in to rate places.'; end if;
  if public.is_banned() then return 'Your account can''t rate places.'; end if;
  if p_stars is null or p_stars < 0.5 or p_stars > 5 or (p_stars * 2) <> floor(p_stars * 2) then
    return 'Pick between half a star and 5 stars.';
  end if;
  if not exists (select 1 from public.places where id = p_place) then
    return 'That place isn''t around anymore.';
  end if;

  select rated_at into last_at from public.place_rating_log
   where place_id = p_place and user_id = uid;
  if last_at is not null and last_at > now() - interval '30 days' then
    return 'You can rate this place again on ' || to_char((last_at + interval '30 days') at time zone 'UTC', 'Mon FMDD') || '.';
  end if;

  insert into public.place_rating_log (place_id, user_id, rated_at)
  values (p_place, uid, now())
  on conflict (place_id, user_id) do update set rated_at = excluded.rated_at;

  insert into public.place_ratings (place_id, user_id, stars, created_at)
  values (p_place, uid, p_stars, now())
  on conflict (place_id, user_id) do update set stars = excluded.stars, created_at = excluded.created_at;

  return null;
end;
$$;

-- Take your rating back any time (the monthly wait still applies).
create or replace function public.remove_my_rating(p_place uuid)
returns void
language sql
security definer set search_path = public
as $$
  delete from public.place_ratings where place_id = p_place and user_id = auth.uid();
$$;

-- One call for the whole app: average + count per place, plus your own
-- rating and when you're next allowed to rate it.
create or replace function public.place_rating_stats()
returns table (place_id uuid, avg_stars numeric, rating_count bigint, my_stars numeric, my_next_at timestamptz)
language sql
stable
security definer set search_path = public
as $$
  select p.place_id,
         round(avg(p.stars), 2) as avg_stars,
         count(*) as rating_count,
         max(p.stars) filter (where p.user_id = auth.uid()) as my_stars,
         (select l.rated_at + interval '30 days' from public.place_rating_log l
           where l.place_id = p.place_id and l.user_id = auth.uid()) as my_next_at
    from public.place_ratings p
   group by p.place_id
  union all
  -- places you rated before and then removed (no ratings left on them)
  select l.place_id, null, 0, null, l.rated_at + interval '30 days'
    from public.place_rating_log l
   where l.user_id = auth.uid()
     and not exists (select 1 from public.place_ratings r where r.place_id = l.place_id);
$$;

grant execute on function public.rate_place(uuid, numeric) to authenticated;
grant execute on function public.remove_my_rating(uuid) to authenticated;
grant execute on function public.place_rating_stats() to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'place_ratings'
  ) then
    alter publication supabase_realtime add table public.place_ratings;
  end if;
end $$;

select 'Phase 9 ready' as status;
