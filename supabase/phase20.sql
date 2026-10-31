-- ============================================================
-- Phase 20: admins can drag an imported venue's pin to the right spot.
-- (Moving a place that's already on the map uses the existing
-- "Admin can verify places" update rule.) Safe to run more than once.
-- ============================================================

create or replace function public.set_venue_location(p_id uuid, p_lat double precision, p_lng double precision)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'That spot isn''t on the map.';
  end if;
  update public.venue_candidates set lat = p_lat, lng = p_lng
  where id = p_id
  returning place_id into pid;
  if not found then raise exception 'That venue is gone.'; end if;
  if pid is not null then
    update public.places set lat = p_lat, lng = p_lng where id = pid;
  end if;
end;
$$;

grant execute on function public.set_venue_location(uuid, double precision, double precision) to authenticated;
