-- ============================================================
-- Phase 19: importing bars & clubs (OpenStreetMap) for admin review.
--
-- The import-venues Edge Function fills venue_candidates with every bar,
-- pub and nightclub within 50 miles of Egg Harbor (free OpenStreetMap
-- data). In the app's Admin panel → New venues, the admin adds a photo,
-- fixes the name/address, approves, denies, or leaves a note. Approving
-- creates a FUNKY-verified place (which never expires) with that photo.
-- Safe to run more than once.
-- ============================================================

create table if not exists public.venue_candidates (
  id uuid primary key default gen_random_uuid(),
  google_place_id text not null unique, -- where it came from, e.g. 'osm:node/123'
  name text not null,
  kind text not null default 'bar' check (kind in ('bar', 'club')),
  address text not null default '',
  lat double precision not null,
  lng double precision not null,
  distance_miles double precision,
  -- [{ "name": "places/…/photos/…", "credit": "Jane D." }, …]
  photos jsonb not null default '[]'::jsonb,
  photo_index integer not null default 0,
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'changes')),
  admin_note text,
  place_id uuid references public.places (id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create index if not exists venue_candidates_status on public.venue_candidates (status);

alter table public.venue_candidates enable row level security;

drop policy if exists "Admins see venue candidates" on public.venue_candidates;
create policy "Admins see venue candidates"
  on public.venue_candidates for select to authenticated
  using (public.is_admin());
-- No insert/update/delete policies: rows come in from the import function
-- (service role) and change only through review_venue() below.

-- A photo the admin added for this venue (public URL in place_covers).
alter table public.venue_candidates add column if not exists custom_photo_url text;

-- Who took the place's picture, when it needs a credit.
alter table public.places add column if not exists photo_credit text;

-- Approving lots of imported venues at once shouldn't send everyone a
-- "New verified place near you" alert for each one.
create or replace function public.notify_place_insert()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.admin_verified and coalesce(current_setting('funky.quiet_place_insert', true), '') <> 'on' then
    perform public.notify_place_verified(new.id);
  end if;
  return new;
end;
$$;

-- decision: 'approve' | 'deny' | 'changes' | 'pending'
-- Optional edits ride along: a new name, address, kind ('bar'/'club'),
-- which photo to use, and a note.
drop function if exists public.review_venue(uuid, text, text, text, text, integer);
create or replace function public.review_venue(
  p_id uuid,
  p_decision text,
  p_note text default null,
  p_name text default null,
  p_kind text default null,
  p_photo_index integer default null,
  p_address text default null
)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  c public.venue_candidates%rowtype;
  new_place uuid;
  photo jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_decision not in ('approve', 'deny', 'changes', 'pending') then raise exception 'Unknown decision.'; end if;

  update public.venue_candidates set
    name = coalesce(nullif(btrim(p_name), ''), name),
    address = coalesce(p_address, address),
    kind = case when p_kind in ('bar', 'club') then p_kind else kind end,
    photo_index = case
      when p_photo_index is not null and p_photo_index >= 0 and p_photo_index < jsonb_array_length(photos) then p_photo_index
      else photo_index end,
    admin_note = case when p_note is not null then nullif(btrim(p_note), '') else admin_note end
  where id = p_id
  returning * into c;
  if not found then raise exception 'That venue is gone.'; end if;

  if p_decision = 'approve' then
    -- The admin's own photo wins; otherwise the picked imported one.
    if c.custom_photo_url is not null then
      photo := jsonb_build_object('url', c.custom_photo_url);
    else
      photo := c.photos -> c.photo_index;
    end if;
    if c.place_id is null or not exists (select 1 from public.places where id = c.place_id) then
      perform set_config('funky.quiet_place_insert', 'on', true);
      insert into public.places (name, kind, lat, lng, address, by_uid, admin_verified, photo_url, photo_credit)
      values (
        left(c.name, 40), c.kind, c.lat, c.lng, left(c.address, 80), auth.uid(), true,
        case when photo is null then null when photo ? 'url' then photo ->> 'url' else 'gplace:' || (photo ->> 'name') end,
        photo ->> 'credit'
      )
      returning id into new_place;
      perform set_config('funky.quiet_place_insert', 'off', true);
    else
      new_place := c.place_id;
      update public.places set
        name = left(c.name, 40),
        kind = c.kind,
        admin_verified = true,
        photo_url = case when photo is null then photo_url when photo ? 'url' then photo ->> 'url' else 'gplace:' || (photo ->> 'name') end,
        photo_credit = case when photo is null then photo_credit else photo ->> 'credit' end
      where id = new_place;
    end if;
    update public.venue_candidates set status = 'approved', place_id = new_place, reviewed_at = now() where id = p_id;
    return new_place;
  end if;

  update public.venue_candidates set
    status = case p_decision when 'deny' then 'denied' when 'changes' then 'changes' else 'pending' end,
    reviewed_at = now()
  where id = p_id;
  return null;
end;
$$;

grant execute on function public.review_venue(uuid, text, text, text, text, integer, text) to authenticated;

-- The admin's photo for a venue (null removes it). If it's already live on
-- the map, the place's picture changes too.
create or replace function public.set_venue_photo(p_id uuid, p_url text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.venue_candidates set custom_photo_url = nullif(btrim(p_url), '')
  where id = p_id
  returning place_id into pid;
  if not found then raise exception 'That venue is gone.'; end if;
  if pid is not null and nullif(btrim(p_url), '') is not null then
    update public.places set photo_url = btrim(p_url), photo_credit = null where id = pid;
  end if;
end;
$$;

grant execute on function public.set_venue_photo(uuid, text) to authenticated;
