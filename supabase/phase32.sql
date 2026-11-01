-- ============================================================
-- Phase 32:
--   1) Crash reports: when the app hits an error it sends a short report
--      (what went wrong, where, which build). Only admins can read them,
--      in the admin panel.
--   2) Top posts win points: each night (2 PM to 2 PM), the 3 best posts
--      in each area (about 30 miles across) by likes minus dislikes get
--      500 / 300 / 150 Funky points. Awarded the first time anyone opens
--      the app after the night ends. A post needs at least 1 net like.
-- Safe to run more than once. Needs phases 27 (funky_night), 29, 30.
-- ============================================================

-- ---- 1) Crash reports -----------------------------------------------------

create table if not exists public.crash_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid default auth.uid(),
  message text not null check (char_length(message) <= 1000),
  stack text check (stack is null or char_length(stack) <= 6000),
  context text check (context is null or char_length(context) <= 500),
  fatal boolean not null default false,
  build text check (build is null or char_length(build) <= 20),
  platform text check (platform is null or char_length(platform) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists crash_reports_created_idx on public.crash_reports (created_at desc);

alter table public.crash_reports enable row level security;
grant insert on public.crash_reports to anon, authenticated;
grant select, delete on public.crash_reports to authenticated;

drop policy if exists "Anyone can send a crash report" on public.crash_reports;
create policy "Anyone can send a crash report" on public.crash_reports for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

drop policy if exists "Admins read crash reports" on public.crash_reports;
create policy "Admins read crash reports" on public.crash_reports for select to authenticated
  using (public.is_admin());

drop policy if exists "Admins clear crash reports" on public.crash_reports;
create policy "Admins clear crash reports" on public.crash_reports for delete to authenticated
  using (public.is_admin());

-- Don't let a crash loop (or anyone) flood the table: past 300 reports in
-- 10 minutes, extra ones are quietly dropped. Old reports go after 30 days.
create or replace function public.crash_reports_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if (select count(*) from public.crash_reports where created_at > now() - interval '10 minutes') >= 300 then
    return null;
  end if;
  delete from public.crash_reports where created_at < now() - interval '30 days';
  return new;
end;
$$;

drop trigger if exists crash_reports_guard on public.crash_reports;
create trigger crash_reports_guard before insert on public.crash_reports
  for each row execute function public.crash_reports_guard();

-- ---- 2) Top posts win points ------------------------------------------------

-- Which area a spot is in: a grid of cells about 30 miles across.
create or replace function public.post_region(lat double precision, lng double precision)
returns text
language sql
immutable
as $$
  select floor(lat / 0.45)::int || ':' || floor(lng / 0.55)::int
$$;

create table if not exists public.post_awards (
  night date not null,
  region text not null,
  rank smallint not null check (rank between 1 and 3),
  post_id uuid references public.posts (id) on delete set null,
  user_id uuid references auth.users (id) on delete cascade,
  points integer not null,
  score integer not null,
  created_at timestamptz not null default now(),
  primary key (night, region, rank)
);

alter table public.post_awards enable row level security;
grant select on public.post_awards to authenticated;

drop policy if exists "See post awards" on public.post_awards;
create policy "See post awards" on public.post_awards for select to authenticated using (true);

-- Hands out last few nights' awards that haven't been given yet. Safe to
-- call any number of times, from anyone's phone. Returns how many it gave.
create or replace function public.award_top_posts()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  tonight date := public.funky_night(now());
  n date;
  r record;
  pts integer;
  inserted integer;
  given integer := 0;
begin
  -- Points are normally admin-only on profiles; this is the server itself
  -- awarding them, so act without the caller's identity from here on.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);

  for n in select d::date from generate_series(tonight - 3, tonight - 1, interval '1 day') d loop
    for r in
      select ranked.*
        from (
          select scored.*,
                 row_number() over (partition by scored.region order by scored.score desc, scored.created_at asc) as rk
            from (
              select p.id, p.uid, p.created_at,
                     public.post_region(p.lat, p.lng) as region,
                     (select count(*) from public.post_likes l where l.post_id = p.id)
                       - (select count(*) from public.post_dislikes d2 where d2.post_id = p.id) as score
                from public.posts p
                join public.profiles pr on pr.id = p.uid
               where public.funky_night(p.created_at) = n
                 and not coalesce(pr.banned, false)
            ) scored
        ) ranked
       where ranked.rk <= 3 and ranked.score >= 1
    loop
      pts := case r.rk when 1 then 500 when 2 then 300 else 150 end;
      insert into public.post_awards (night, region, rank, post_id, user_id, points, score)
      values (n, r.region, r.rk, r.id, r.uid, pts, r.score)
      on conflict do nothing;
      get diagnostics inserted = row_count;
      if inserted = 1 then
        update public.profiles set bonus_points = bonus_points + pts where id = r.uid;
        perform public.push_notify(
          r.uid, 'post_award',
          'Your post was #' || r.rk || ' last night 🏆',
          '+' || pts || ' Funky points. Keep it up.',
          jsonb_build_object('post_id', r.id, 'rank', r.rk::text));
        given := given + 1;
      end if;
    end loop;
  end loop;
  return given;
end;
$$;

grant execute on function public.award_top_posts() to authenticated;
