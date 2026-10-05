-- ============================================================
-- FUNKY phase 3 — run once in the Supabase SQL Editor (after phase2.sql).
-- Adds: shared live-chat reactions, shared place cover photos.
-- Safe to re-run.
-- ============================================================

-- 1. Live-chat reactions (one reaction per person per message)

create table if not exists public.chat_reactions (
  message_id uuid not null references public.chat_messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.chat_reactions enable row level security;

drop policy if exists "See live chat reactions" on public.chat_reactions;
create policy "See live chat reactions"
  on public.chat_reactions for select to authenticated using (true);

drop policy if exists "React as yourself" on public.chat_reactions;
create policy "React as yourself"
  on public.chat_reactions for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists "Change your own reaction" on public.chat_reactions;
create policy "Change your own reaction"
  on public.chat_reactions for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and not public.is_banned());

drop policy if exists "Remove your own reaction" on public.chat_reactions;
create policy "Remove your own reaction"
  on public.chat_reactions for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop trigger if exists rate_limit_chat_reactions on public.chat_reactions;
create trigger rate_limit_chat_reactions before insert on public.chat_reactions
  for each row execute procedure public.rate_limit('user_id', '60', '60');

-- 2. Place cover photos

alter table public.places add column if not exists cover_url text;

insert into storage.buckets (id, name, public, file_size_limit)
values ('place_covers', 'place_covers', true, 8388608)
on conflict (id) do nothing;

drop policy if exists "Upload your own place cover" on storage.objects;
create policy "Upload your own place cover"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'place_covers' and (storage.foldername(name)) [1] = auth.uid()::text);

drop policy if exists "Anyone can see place covers" on storage.objects;
create policy "Anyone can see place covers"
  on storage.objects for select to authenticated
  using (bucket_id = 'place_covers');

drop policy if exists "Delete your own place cover" on storage.objects;
create policy "Delete your own place cover"
  on storage.objects for delete to authenticated
  using (bucket_id = 'place_covers' and ((storage.foldername(name)) [1] = auth.uid()::text or public.is_admin()));

-- 3. Realtime

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_reactions'
  ) then
    alter publication supabase_realtime add table public.chat_reactions;
  end if;
end $$;
