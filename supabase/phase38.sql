-- ============================================================
-- Phase 38: Memories
--   1) A photo or video Story posted at a place is saved as a Memory
--      automatically (it never auto-deletes). Stories already up that were
--      posted at a place get saved too.
--   2) Unsaved Memories are deleted 7 days after they were posted (text
--      Stories, which never become Memories, after 2 days). The app calls
--      purge_expired_memories() when it opens.
--   3) The deleted Stories' files are listed in storage_trash so the
--      owner's app (or an admin's) can remove them from Storage.
-- Safe to run more than once. Needs phases 2, 28.
-- ============================================================

-- ---- 1) Stories at a place save themselves ---------------------------------

create or replace function public.place_stories_autosave()
returns trigger
language plpgsql
as $$
begin
  if new.place_id is not null and new.place_id <> 'main' and new.media_path is not null then
    new.saved_to_timeline := true;
  end if;
  return new;
end;
$$;

drop trigger if exists stories_place_autosave on public.stories;
create trigger stories_place_autosave
  before insert on public.stories
  for each row execute function public.place_stories_autosave();

update public.stories
   set saved_to_timeline = true
 where place_id is not null and place_id <> 'main' and media_path is not null
   and not saved_to_timeline;

-- ---- 3) Files waiting to be removed from Storage ----------------------------

create table if not exists public.storage_trash (
  id bigserial primary key,
  bucket text not null,
  path text not null,
  owner_id uuid not null,
  created_at timestamptz not null default now(),
  unique (bucket, path)
);

alter table public.storage_trash enable row level security;
revoke all on public.storage_trash from anon;
grant select, delete on public.storage_trash to authenticated;

drop policy if exists "Clean up your own deleted files" on public.storage_trash;
create policy "Clean up your own deleted files" on public.storage_trash for select to authenticated
  using (owner_id = auth.uid() or public.is_admin());

drop policy if exists "Clear your own deleted files" on public.storage_trash;
create policy "Clear your own deleted files" on public.storage_trash for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin());

-- An admin's app can clear anyone's leftover Story files.
drop policy if exists "Admins delete story media" on storage.objects;
create policy "Admins delete story media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'stories' and public.is_admin());

-- ---- 2) Delete expired Memories ---------------------------------------------

create or replace function public.purge_expired_memories()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  if auth.uid() is null then return 0; end if;
  with gone as (
    delete from public.stories
     where not saved_to_timeline
       and (
         created_at < now() - interval '7 days'
         or (media_path is null and created_at < now() - interval '2 days')
       )
    returning uid, media_path
  )
  insert into public.storage_trash (bucket, path, owner_id)
  select 'stories', media_path, uid from gone where media_path is not null
  on conflict (bucket, path) do nothing;
  get diagnostics n = row_count;
  -- Files nobody could remove in a month are dropped from the list.
  delete from public.storage_trash where created_at < now() - interval '30 days';
  return n;
end;
$$;

revoke all on function public.purge_expired_memories() from public, anon;
grant execute on function public.purge_expired_memories() to authenticated;
