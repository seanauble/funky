-- ============================================================
-- Phase 30: posts get dislikes, text-only posts ("Anyone up for
-- trivia?"), and the town they were posted in.
--   * A post can be just text (no photos), or 1-5 photos with a caption.
--   * Like or dislike a post (one or the other, never both). Feeds sort
--     by likes minus dislikes.
-- Safe to run more than once. Needs phase 29.
-- ============================================================

alter table public.posts add column if not exists area_name text;
alter table public.posts drop constraint if exists posts_area_name_len;
alter table public.posts add constraint posts_area_name_len
  check (area_name is null or char_length(area_name) <= 60);

alter table public.posts alter column photo_paths set default '{}';
alter table public.posts drop constraint if exists posts_photo_paths_check;
alter table public.posts drop constraint if exists posts_has_content;
alter table public.posts add constraint posts_has_content check (
  coalesce(array_length(photo_paths, 1), 0) <= 5
  and (coalesce(array_length(photo_paths, 1), 0) >= 1 or char_length(btrim(caption)) >= 1)
);

-- ---- Dislikes -----------------------------------------------------------

create table if not exists public.post_dislikes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_dislikes enable row level security;
grant select, insert, delete on public.post_dislikes to authenticated;

drop policy if exists "See post dislikes" on public.post_dislikes;
create policy "See post dislikes" on public.post_dislikes for select to authenticated using (true);

drop policy if exists "Dislike as yourself" on public.post_dislikes;
create policy "Dislike as yourself" on public.post_dislikes for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned() and not public.is_guest());

drop policy if exists "Undo your own dislike" on public.post_dislikes;
create policy "Undo your own dislike" on public.post_dislikes for delete to authenticated
  using (auth.uid() = user_id);

-- A like cancels your dislike and the other way round.
create or replace function public.post_vote_exclusive()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if tg_table_name = 'post_likes' then
    delete from public.post_dislikes where post_id = new.post_id and user_id = new.user_id;
  else
    delete from public.post_likes where post_id = new.post_id and user_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists post_likes_exclusive on public.post_likes;
create trigger post_likes_exclusive
  after insert on public.post_likes
  for each row execute function public.post_vote_exclusive();

drop trigger if exists post_dislikes_exclusive on public.post_dislikes;
create trigger post_dislikes_exclusive
  after insert on public.post_dislikes
  for each row execute function public.post_vote_exclusive();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'post_dislikes'
  ) then
    alter publication supabase_realtime add table public.post_dislikes;
  end if;
end $$;
