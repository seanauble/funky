-- ============================================================
-- Phase 15: guest mode.
--
-- People without an account browse with a Supabase *anonymous* session
-- (turn on: Supabase → Authentication → Sign In / Providers →
-- "Allow anonymous sign-ins"). They're "authenticated" as far as the
-- database is concerned, so Places, Live Chat, place reports/ratings and
-- viewing Stories just work for them. These extra RESTRICTIVE rules keep
-- guests from the account-only stuff: liking Stories, posting Stories,
-- reacting to chat, DMs, group messages and friend requests.
-- Safe to run more than once.
-- ============================================================

create or replace function public.is_guest()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

grant execute on function public.is_guest() to authenticated;

drop policy if exists "Guests can't like stories" on public.story_likes;
create policy "Guests can't like stories"
  on public.story_likes as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't post stories" on public.stories;
create policy "Guests can't post stories"
  on public.stories as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't react to chat" on public.chat_reactions;
create policy "Guests can't react to chat"
  on public.chat_reactions as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't change chat reactions" on public.chat_reactions;
create policy "Guests can't change chat reactions"
  on public.chat_reactions as restrictive for update to authenticated
  using (not public.is_guest());

drop policy if exists "Guests can't send DMs" on public.messages;
create policy "Guests can't send DMs"
  on public.messages as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't message groups" on public.group_messages;
create policy "Guests can't message groups"
  on public.group_messages as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't send friend requests" on public.friendships;
create policy "Guests can't send friend requests"
  on public.friendships as restrictive for insert to authenticated
  with check (not public.is_guest());

drop policy if exists "Guests can't accept friend requests" on public.friendships;
create policy "Guests can't accept friend requests"
  on public.friendships as restrictive for update to authenticated
  using (not public.is_guest());

-- Old guest sessions pile up as anonymous users; clean out ones that have
-- been idle for 30 days (their chat messages and places go with them only
-- if the tables cascade — profiles do). Run by hand whenever you like:
--   select public.purge_old_guests();
create or replace function public.purge_old_guests()
returns integer
language plpgsql
security definer set search_path = public, auth
as $$
declare
  n integer;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  with del as (
    delete from auth.users
    where is_anonymous
      and coalesce(last_sign_in_at, created_at) < now() - interval '30 days'
    returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_old_guests() to authenticated;
