-- ============================================================
-- Phase 26:
--   1) Every Story gets a location, so "your radius reaches it" works for
--      everyone. A Story posted without one (an older app version, or GPS
--      wasn't ready yet) takes its venue's spot, or else the poster's last
--      known location. Stories from the last 2 days are back-filled.
--   2) Report a Story: the flag on a Story sends it to the FUNKY admins,
--      with a copy of the Story (even if it's anonymous or expires), to
--      dismiss or remove.
-- Safe to run more than once.
-- ============================================================

alter table public.stories add column if not exists lat double precision;
alter table public.stories add column if not exists lng double precision;

create or replace function public.fill_story_location()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  plat double precision;
  plng double precision;
begin
  if new.lat is not null and new.lng is not null then
    return new;
  end if;
  if new.place_id is not null and new.place_id <> 'main' then
    select p.lat, p.lng into plat, plng from public.places p where p.id::text = lower(new.place_id);
  end if;
  if plat is null then
    select ul.lat, ul.lng into plat, plng
      from public.user_locations ul
     where ul.user_id = new.uid
       and ul.updated_at > now() - interval '3 days';
  end if;
  if plat is not null and plng is not null then
    new.lat := plat;
    new.lng := plng;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_fill_location on public.stories;
create trigger stories_fill_location
  before insert on public.stories
  for each row execute function public.fill_story_location();

-- Back-fill recent Stories that were posted without a location.
update public.stories s
   set lat = p.lat, lng = p.lng
  from public.places p
 where s.lat is null
   and s.created_at > now() - interval '2 days'
   and s.place_id is not null
   and p.id::text = lower(s.place_id);

update public.stories s
   set lat = ul.lat, lng = ul.lng
  from public.user_locations ul
 where s.lat is null
   and s.created_at > now() - interval '2 days'
   and ul.user_id = s.uid;

-- ---- Story reports --------------------------------------------------

create table if not exists public.story_reports (
  id uuid primary key default gen_random_uuid(),
  story_id uuid references public.stories (id) on delete set null,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  poster_id uuid references auth.users (id) on delete cascade,
  reason text not null check (char_length(reason) between 2 and 80),
  -- A copy of the Story so it can still be reviewed after it expires or
  -- is deleted.
  story_text text,
  story_media_path text,
  story_is_video boolean not null default false,
  story_anon boolean not null default false,
  story_place_name text,
  story_created_at timestamptz,
  status text not null default 'open' check (status in ('open', 'resolved')),
  outcome text check (outcome is null or outcome in ('dismissed', 'removed')),
  created_at timestamptz not null default now()
);

create unique index if not exists story_report_one_open
  on public.story_reports (reporter_id, story_id) where status = 'open';
create index if not exists story_reports_open_idx
  on public.story_reports (created_at) where status = 'open';

alter table public.story_reports enable row level security;
grant select on public.story_reports to authenticated;

-- Only admins read reports. Filing one goes through report_story.
drop policy if exists "Admins see story reports" on public.story_reports;
create policy "Admins see story reports"
  on public.story_reports for select to authenticated
  using (public.is_admin());

-- Admins can open any Story picture/video (to review a reported one).
drop policy if exists "Admins read all story media" on storage.objects;
create policy "Admins read all story media"
  on storage.objects for select to authenticated
  using (bucket_id = 'stories' and public.is_admin());

-- File a report. Returns null when it worked, otherwise a message to show.
create or replace function public.report_story(p_story uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
  s public.stories%rowtype;
  rid uuid;
  who text;
  a record;
begin
  if uid is null then return 'Sign in to report a story.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  select * into s from public.stories where id = p_story;
  if not found then return 'That story isn''t up anymore.'; end if;
  if s.uid = uid then return 'That''s your own story.'; end if;
  if exists (select 1 from public.story_reports
              where reporter_id = uid and story_id = p_story and status = 'open') then
    return 'You already reported this story. The FUNKY team will take a look.';
  end if;
  if (select count(*) from public.story_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 15 then
    return 'That''s a lot of reports for one day. Try again tomorrow.';
  end if;

  insert into public.story_reports (
    story_id, reporter_id, poster_id, reason,
    story_text, story_media_path, story_is_video, story_anon, story_place_name, story_created_at)
  values (
    s.id, uid, s.uid, r,
    left(s.text, 300), s.media_path, coalesce(s.is_video, false), coalesce(s.anon, false), s.place_name, s.created_at)
  returning id into rid;

  -- Ping the admins on the first report for this Story.
  if (select count(*) from public.story_reports where story_id = s.id and status = 'open') = 1 then
    select handle into who from public.profiles where id = s.uid;
    for a in
      select p.id from public.profiles p
       where p.is_admin
          or p.id in (select u.id from auth.users u where lower(u.email) = 'seanauble@icloud.com')
    loop
      if a.id <> uid then
        perform public.push_notify(
          a.id, 'story_report', 'Story reported',
          (case when coalesce(s.anon, false) then 'An anonymous story' else '@' || coalesce(who, 'someone') || '''s story' end)
            || ' was reported: ' || r,
          jsonb_build_object('report_id', rid, 'story_id', s.id));
      end if;
    end loop;
  end if;
  return null;
end;
$$;

-- Admin: close a report (and every other open report on the same Story).
-- p_remove = true also deletes the Story and lets the poster know.
create or replace function public.resolve_story_report(p_id uuid, p_remove boolean default false)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  rep public.story_reports%rowtype;
begin
  if not public.is_admin() then return 'Admins only.'; end if;
  select * into rep from public.story_reports where id = p_id;
  if not found then return 'That report is gone.'; end if;

  update public.story_reports
     set status = 'resolved',
         outcome = case when p_remove then 'removed' else 'dismissed' end
   where status = 'open'
     and (id = p_id or (rep.story_id is not null and story_id = rep.story_id));

  if p_remove then
    if rep.story_id is not null then
      delete from public.stories where id = rep.story_id;
    end if;
    if rep.poster_id is not null then
      perform public.push_notify(
        rep.poster_id, 'moderation', 'Your story was removed',
        'One of your stories broke the FUNKY community rules (' || rep.reason || ') and was taken down.',
        '{}'::jsonb);
    end if;
  end if;
  return null;
end;
$$;

grant execute on function public.report_story(uuid, text) to authenticated;
grant execute on function public.resolve_story_report(uuid, boolean) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'story_reports'
  ) then
    alter publication supabase_realtime add table public.story_reports;
  end if;
end $$;
