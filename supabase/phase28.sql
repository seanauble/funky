-- ============================================================
-- Phase 28:
--   1) One poll a day per person (the night rolls over at 2 PM Eastern).
--      Deleting your poll doesn't give you another one that night.
--      FUNKY admins aren't limited.
--   2) Text-only Stories never become Memories (can't be saved to the
--      Timeline). Only photo and video Stories are kept.
-- Safe to run more than once. Needs phase 27 (funky_night).
-- ============================================================

create table if not exists public.poll_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  night date not null,
  created_at timestamptz not null default now(),
  primary key (user_id, night)
);

-- Nobody reads or writes this directly; only the trigger below does.
alter table public.poll_daily enable row level security;

create or replace function public.one_poll_a_day()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  insert into public.poll_daily (user_id, night)
  values (auth.uid(), public.funky_night(now()))
  on conflict (user_id, night) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'You can only post one poll a day. Check back after the 2 PM reset.';
  end if;
  return new;
end;
$$;

drop trigger if exists one_poll_a_day on public.polls;
create trigger one_poll_a_day
  before insert on public.polls
  for each row execute function public.one_poll_a_day();

-- Anyone who already posted a poll tonight has used tonight's.
insert into public.poll_daily (user_id, night)
select distinct p.by_uid, public.funky_night(p.created_at)
  from public.polls p
 where p.by_uid is not null
   and p.created_at > now() - interval '2 days'
   and exists (select 1 from auth.users u where u.id = p.by_uid)
on conflict (user_id, night) do nothing;

-- Text-only Stories can't be saved as Memories.
create or replace function public.text_stories_not_memories()
returns trigger
language plpgsql
as $$
begin
  if new.media_path is null then
    new.saved_to_timeline := false;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_text_not_memories on public.stories;
create trigger stories_text_not_memories
  before insert or update on public.stories
  for each row execute function public.text_stories_not_memories();

update public.stories set saved_to_timeline = false
 where media_path is null and saved_to_timeline;
