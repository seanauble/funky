-- ============================================================
-- PHASE 10 — Admin approvals: anyone can suggest a picture for a place (a
-- FUNKY Admin approves it before it shows up for everyone), and anyone can
-- report a profile (the admin reviews the reports).
-- Safe to re-run. Needs phases 2, 3 and 7 first.
-- ============================================================

-- The approved picture shown on the map, in lists and on the place page.
alter table public.places add column if not exists photo_url text;

create table if not exists public.place_photo_suggestions (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  url text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);

-- One waiting picture per person per place.
create unique index if not exists place_photo_one_pending
  on public.place_photo_suggestions (place_id, user_id) where status = 'pending';

alter table public.place_photo_suggestions enable row level security;

-- You see your own suggestions; the admin sees all. No insert/update/delete
-- policies: everything goes through the functions below.
drop policy if exists "See own or admin photo suggestions" on public.place_photo_suggestions;
create policy "See own or admin photo suggestions"
  on public.place_photo_suggestions for select to authenticated
  using (auth.uid() = user_id or public.is_admin());

-- Suggest a picture (its file is already uploaded to the place_covers
-- bucket under your own folder). An admin's picture goes live right away;
-- anyone else's waits for approval. Returns 'approved', 'pending', or an
-- error message starting with "!".
create or replace function public.suggest_place_photo(p_place uuid, p_url text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return '!Sign in to add a picture.'; end if;
  if public.is_banned() then return '!Your account can''t add pictures.'; end if;
  if p_url is null or length(p_url) < 10 or length(p_url) > 600 then return '!Bad picture.'; end if;
  if not exists (select 1 from public.places where id = p_place) then
    return '!That place isn''t around anymore.';
  end if;

  if public.is_admin() then
    update public.places set photo_url = p_url where id = p_place;
    return 'approved';
  end if;

  if (select count(*) from public.place_photo_suggestions
       where user_id = uid and created_at > now() - interval '1 day') >= 5 then
    return '!That''s enough pictures for today — try again tomorrow.';
  end if;

  -- A newer suggestion replaces your earlier waiting one for this place.
  delete from public.place_photo_suggestions
   where place_id = p_place and user_id = uid and status = 'pending';
  insert into public.place_photo_suggestions (place_id, user_id, url) values (p_place, uid, p_url);
  return 'pending';
end;
$$;

-- Admin: approve or reject a waiting picture. The person who suggested it
-- gets a notification either way.
create or replace function public.review_place_photo(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  s public.place_photo_suggestions;
  pname text;
begin
  if not public.is_admin() then return; end if;
  select * into s from public.place_photo_suggestions where id = p_id and status = 'pending';
  if not found then return; end if;
  select name into pname from public.places where id = s.place_id;

  if p_approve then
    update public.places set photo_url = s.url where id = s.place_id;
    update public.place_photo_suggestions set status = 'approved' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Your picture was approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' is live.',
      jsonb_build_object('place_id', s.place_id));
  else
    update public.place_photo_suggestions set status = 'rejected' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Picture not approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' wasn''t approved.',
      jsonb_build_object('place_id', s.place_id));
  end if;
end;
$$;

-- Admin: take the current picture off a place.
create or replace function public.clear_place_photo(p_place uuid)
returns void
language sql
security definer set search_path = public
as $$
  update public.places set photo_url = null where id = p_place and public.is_admin();
$$;

grant execute on function public.suggest_place_photo(uuid, text) to authenticated;
grant execute on function public.review_place_photo(uuid, boolean) to authenticated;
grant execute on function public.clear_place_photo(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'place_photo_suggestions'
  ) then
    alter publication supabase_realtime add table public.place_photo_suggestions;
  end if;
end $$;

-- ------------------------------------------------------------
-- Profile reports
-- ------------------------------------------------------------

create table if not exists public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reported_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null check (char_length(reason) between 2 and 80),
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_at timestamptz not null default now()
);

create unique index if not exists profile_report_one_open
  on public.profile_reports (reporter_id, reported_id) where status = 'open';

alter table public.profile_reports enable row level security;

-- Only the admin reads reports. Filing one goes through report_profile.
drop policy if exists "Admin sees profile reports" on public.profile_reports;
create policy "Admin sees profile reports"
  on public.profile_reports for select to authenticated
  using (public.is_admin());

-- File a report. Returns null when it worked, otherwise a message to show.
create or replace function public.report_profile(p_user uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
begin
  if uid is null then return 'Sign in to report someone.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if p_user is null or p_user = uid then return 'You can''t report yourself.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return 'That profile isn''t around anymore.'; end if;
  if exists (select 1 from public.profile_reports
              where reporter_id = uid and reported_id = p_user and status = 'open') then
    return 'You already reported this person — the team will take a look.';
  end if;
  if (select count(*) from public.profile_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 10 then
    return 'That''s a lot of reports for one day — try again tomorrow.';
  end if;
  insert into public.profile_reports (reporter_id, reported_id, reason) values (uid, p_user, r);
  return null;
end;
$$;

-- Admin: mark a report as dealt with.
create or replace function public.resolve_profile_report(p_id uuid)
returns void
language sql
security definer set search_path = public
as $$
  update public.profile_reports set status = 'resolved' where id = p_id and public.is_admin();
$$;

grant execute on function public.report_profile(uuid, text) to authenticated;
grant execute on function public.resolve_profile_report(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profile_reports'
  ) then
    alter publication supabase_realtime add table public.profile_reports;
  end if;
end $$;

select 'Phase 10 ready' as status;
