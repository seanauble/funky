-- ============================================================
-- Phase 22: fill in an imported venue's street address.
-- OpenStreetMap often has the exact pin but no address; the app looks
-- the address up from the pin and saves it here. Safe to run more than once.
-- ============================================================

create or replace function public.set_venue_address(p_id uuid, p_address text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.venue_candidates set address = left(btrim(coalesce(p_address, '')), 120)
  where id = p_id
  returning place_id into pid;
  if pid is not null then
    update public.places set address = left(btrim(coalesce(p_address, '')), 80)
    where id = pid and address = '';
  end if;
end;
$$;

grant execute on function public.set_venue_address(uuid, text) to authenticated;
