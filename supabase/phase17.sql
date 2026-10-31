-- ============================================================
-- Phase 17: friend counts on profiles.
-- Friendships are private (you can only read your own rows), so a
-- profile's "Friends" number comes from this count-only function — it
-- never reveals WHO someone's friends are. Safe to run more than once.
-- ============================================================

create or replace function public.friend_count(p_user uuid)
returns integer
language sql
stable
security definer set search_path = public
as $$
  select count(*)::int
  from public.friendships f
  where f.status = 'accepted'
    and (f.requester_id = p_user or f.addressee_id = p_user)
$$;

grant execute on function public.friend_count(uuid) to authenticated;
