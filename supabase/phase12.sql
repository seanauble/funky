-- ============================================================
-- PHASE 12 — Your own "near me" distance (1–50 miles) and group photos.
-- Safe to re-run. Needs phases 7 and 11 first.
-- ============================================================

-- ---- Per-person radius, used for "new verified place near you" alerts ----

alter table public.user_locations
  add column if not exists radius_miles integer;

alter table public.user_locations
  drop constraint if exists user_locations_radius_miles_check;
alter table public.user_locations
  add constraint user_locations_radius_miles_check
  check (radius_miles is null or radius_miles between 1 and 50);

create or replace function public.notify_place_verified(pid uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pl public.places%rowtype;
begin
  select * into pl from public.places where id = pid;
  if not found then return; end if;

  insert into public.notifications (user_id, kind, title, body, data)
  select ul.user_id, 'place', 'New verified place near you',
         pl.name || ' is now verified on FUNKY',
         jsonb_build_object('place_id', pl.id)
    from public.user_locations ul
    left join public.notification_prefs np on np.user_id = ul.user_id
   cross join lateral (select coalesce(ul.radius_miles, 25)::double precision as r) rad
   where ul.user_id is distinct from pl.by_uid
     and coalesce(np.place_on, true)
     -- cheap box first (a degree of latitude is about 69 miles; longitude
     -- shrinks with latitude), then the exact great-circle distance.
     and ul.lat between pl.lat - rad.r / 69.0 and pl.lat + rad.r / 69.0
     and ul.lng between pl.lng - rad.r / (69.172 * greatest(0.01, cos(radians(pl.lat))))
                    and pl.lng + rad.r / (69.172 * greatest(0.01, cos(radians(pl.lat))))
     and 3958.8 * 2 * asin(least(1, sqrt(
           power(sin(radians(ul.lat - pl.lat) / 2), 2) +
           cos(radians(pl.lat)) * cos(radians(ul.lat)) *
           power(sin(radians(ul.lng - pl.lng) / 2), 2)
         ))) <= rad.r
     and not exists (
       select 1 from public.notifications n
        where n.user_id = ul.user_id
          and n.kind = 'place'
          and n.data ->> 'place_id' = pl.id::text
     );
end;
$$;

revoke all on function public.notify_place_verified(uuid) from public, anon, authenticated;

-- ---- A picture for a group chat -------------------------------------

alter table public.group_chats
  add column if not exists photo_url text;

create or replace function public.set_group_photo(p_group uuid, p_url text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  u text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group.'; end if;
  -- Only a picture this app uploaded (the public place_covers storage bucket).
  if u is not null and (char_length(u) > 600
      or u !~* '^https://[a-z0-9.-]+/storage/v1/object/public/place_covers/') then
    raise exception 'That picture link isn''t valid.';
  end if;
  update public.group_chats set photo_url = u where id = p_group;
end;
$$;

grant execute on function public.set_group_photo(uuid, text) to authenticated;

select 'Phase 12 ready' as status;
