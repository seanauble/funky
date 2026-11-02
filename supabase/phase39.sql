-- ============================================================
-- Phase 39: Comments on polls
--   Anyone with an account can comment on a poll ("Charlie's never
--   misses"). The poll's owner gets a notification. Comments go with the
--   poll when it's deleted.
-- Safe to run more than once. Needs phases 2, 7, 15, 31.
-- ============================================================

create table if not exists public.poll_comments (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls (id) on delete cascade,
  uid uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  text text not null check (char_length(text) between 1 and 300),
  created_at timestamptz not null default now()
);

create index if not exists poll_comments_poll_idx on public.poll_comments (poll_id, created_at);

alter table public.poll_comments enable row level security;
grant select, insert, delete on public.poll_comments to authenticated;

drop policy if exists "See poll comments" on public.poll_comments;
create policy "See poll comments" on public.poll_comments for select to authenticated using (true);

drop policy if exists "Comment on a poll as yourself" on public.poll_comments;
create policy "Comment on a poll as yourself" on public.poll_comments for insert to authenticated
  with check (uid = auth.uid() and not public.is_banned() and not public.is_guest());

drop policy if exists "Delete a poll comment" on public.poll_comments;
create policy "Delete a poll comment" on public.poll_comments for delete to authenticated
  using (
    uid = auth.uid()
    or public.is_admin()
    or exists (select 1 from public.polls p where p.id = poll_id and p.by_uid = auth.uid())
  );

drop trigger if exists rate_limit_poll_comments on public.poll_comments;
create trigger rate_limit_poll_comments before insert on public.poll_comments
  for each row execute procedure public.rate_limit('uid', '60', '10');

create or replace function public.notify_poll_comment()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  owner uuid;
  q text;
  who text;
begin
  select by_uid, polls.q into owner, q from public.polls where id = new.poll_id;
  if owner is null or owner = new.uid then
    return new;
  end if;
  select handle into who from public.profiles where id = new.uid;
  perform public.push_notify(
    owner, 'poll_comment', '@' || coalesce(who, 'someone') || ' commented on your poll',
    left(new.text, 120),
    jsonb_build_object('poll_id', new.poll_id, 'from', new.uid));
  return new;
end;
$$;

revoke all on function public.notify_poll_comment() from public, anon, authenticated;

drop trigger if exists poll_comments_notify on public.poll_comments;
create trigger poll_comments_notify after insert on public.poll_comments
  for each row execute function public.notify_poll_comment();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'poll_comments'
     ) then
    alter publication supabase_realtime add table public.poll_comments;
  end if;
end;
$$;
