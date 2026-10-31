-- ============================================================
-- Phase 21: the admin's phone imports bars & clubs itself.
-- The app downloads the list from OpenStreetMap directly (the shared
-- servers Supabase functions run on get turned away as "busy") and hands
-- it to this function, which adds anything new for review. Skips venues
-- already imported or already on the map under the same name nearby.
-- Safe to run more than once.
-- ============================================================

create or replace function public.import_venue_candidates(p_rows jsonb)
returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  r jsonb;
  n integer := 0;
  v_lat double precision;
  v_lng double precision;
  v_name text;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'Expected a list.'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := left(btrim(coalesce(r ->> 'name', '')), 60);
    v_lat := (r ->> 'lat')::double precision;
    v_lng := (r ->> 'lng')::double precision;
    continue when v_name = '' or v_lat is null or v_lng is null or coalesce(r ->> 'source_id', '') = '';
    -- Already on the map under that name, within about 0.2 miles.
    continue when exists (
      select 1 from public.places p
      where lower(p.name) = lower(v_name)
        and abs(p.lat - v_lat) < 0.003
        and abs(p.lng - v_lng) < 0.004
    );
    insert into public.venue_candidates (google_place_id, name, kind, address, lat, lng, distance_miles, photos)
    values (
      r ->> 'source_id',
      v_name,
      case when r ->> 'kind' = 'club' then 'club' else 'bar' end,
      left(coalesce(r ->> 'address', ''), 120),
      v_lat,
      v_lng,
      nullif(r ->> 'distance_miles', '')::double precision,
      '[]'::jsonb
    )
    on conflict (google_place_id) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

grant execute on function public.import_venue_candidates(jsonb) to authenticated;
