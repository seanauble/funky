-- ============================================================
-- Phase 18: admins can set their "near me" radius up to 5,000 miles.
-- Everyone else stays at 1–50 (anything bigger from a non-admin is
-- quietly capped at 50). Safe to run more than once.
-- ============================================================

alter table public.user_locations
  drop constraint if exists user_locations_radius_miles_check;
alter table public.user_locations
  add constraint user_locations_radius_miles_check
  check (radius_miles is null or radius_miles between 1 and 5000);

create or replace function public.cap_radius_miles()
returns trigger
language plpgsql
as $$
begin
  if new.radius_miles is not null and new.radius_miles > 50 and not public.is_admin() then
    new.radius_miles := 50;
  end if;
  return new;
end;
$$;

drop trigger if exists cap_radius_miles on public.user_locations;
create trigger cap_radius_miles
  before insert or update on public.user_locations
  for each row execute procedure public.cap_radius_miles();
