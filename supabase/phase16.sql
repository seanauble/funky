-- ============================================================
-- Phase 16: only FUNKY Admin-verified places last past 24 hours.
-- Places confirmed by the crowd (15+ people) are still "verified" for the
-- night, but now clear out 24 hours after they were added like any other.
-- Safe to run more than once.
-- ============================================================

create or replace function public.purge_stale_places()
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  n integer;
begin
  with del as (
    delete from public.places p
    where p.created_at < now() - interval '24 hours'
      and p.admin_verified = false
    returning 1
  )
  select count(*) into n from del;
  return coalesce(n, 0);
end;
$$;

grant execute on function public.purge_stale_places() to authenticated;

-- Clear out the ones that are already past their 24 hours.
select public.purge_stale_places() as stale_places_removed;
