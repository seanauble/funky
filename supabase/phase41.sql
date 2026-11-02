-- ============================================================
-- Phase 41: Bar and club owners
--   1) Claim a place: an owner (or manager) asks to run a bar's page; a
--      FUNKY admin checks it's really them and approves it.
--   2) Owners skip the line: an event an owner posts at their own place is
--      verified right away (no 15 confirmations, no admin) and marked
--      Official. Everyone else's events still need verifying.
--   3) Owners' pictures for their place go live without approval.
--   4) A deal box on the place ("No cover before 10").
-- Safe to run more than once. Needs phases 2, 7, 10, 33.
-- ============================================================

-- ---- 1) Claims ---------------------------------------------------------------

create table if not exists public.place_claims (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  role text check (role is null or char_length(role) <= 40),
  contact text check (contact is null or char_length(contact) <= 120),
  note text check (note is null or char_length(note) <= 300),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  unique (place_id, user_id)
);

create index if not exists place_claims_status_idx on public.place_claims (status, created_at);

alter table public.place_claims enable row level security;
grant select, delete on public.place_claims to authenticated;

-- Everyone can see who runs a place (for the Owner badge); you see your own
-- requests; admins see everything.
drop policy if exists "See place owners and your claims" on public.place_claims;
create policy "See place owners and your claims" on public.place_claims for select to authenticated
  using (status = 'approved' or user_id = auth.uid() or public.is_admin());

drop policy if exists "Withdraw your claim" on public.place_claims;
create policy "Withdraw your claim" on public.place_claims for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

create or replace function public.is_place_owner(p uuid)
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.place_claims
     where place_id = p and user_id = auth.uid() and status = 'approved'
  )
$$;

grant execute on function public.is_place_owner(uuid) to authenticated;

-- Ask to run a bar or club's page. Returns 'pending', 'approved' (already
-- yours) or an error starting with '!'.
create or replace function public.submit_place_claim(p_place uuid, p_role text, p_contact text, p_note text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  pl record;
  who text;
  existing text;
  admin_row record;
begin
  if me is null or public.is_guest() then return '!Make an account to claim a place.'; end if;
  if public.is_banned() then return '!Your account can''t claim places.'; end if;
  select id, name, kind into pl from public.places where id = p_place;
  if not found then return '!That place isn''t around anymore.'; end if;
  if pl.kind not in ('bar', 'club') then return '!Only bars and clubs can be claimed.'; end if;
  if coalesce(btrim(p_contact), '') = '' then
    return '!Add a phone number, email or Instagram we can check you with.';
  end if;
  select status into existing from public.place_claims where place_id = p_place and user_id = me;
  if existing = 'approved' then return 'approved'; end if;
  if (select count(*) from public.place_claims where user_id = me and created_at > now() - interval '1 day') >= 5 then
    return '!That''s enough claims for today.';
  end if;
  insert into public.place_claims (place_id, user_id, status, role, contact, note)
  values (p_place, me, 'pending', left(nullif(btrim(p_role), ''), 40), left(btrim(p_contact), 120), left(nullif(btrim(p_note), ''), 300))
  on conflict (place_id, user_id) do update
    set status = 'pending', role = excluded.role, contact = excluded.contact, note = excluded.note,
        created_at = now(), decided_at = null, decided_by = null;
  select handle into who from public.profiles where id = me;
  for admin_row in select id from public.profiles where is_admin and id <> me loop
    perform public.push_notify(
      admin_row.id, 'claim_request',
      '@' || coalesce(who, 'someone') || ' wants to claim ' || coalesce(pl.name, 'a place'),
      'Check it''s really them, then approve it in the Admin panel.',
      jsonb_build_object('place_id', p_place, 'from', me));
  end loop;
  return 'pending';
end;
$$;

grant execute on function public.submit_place_claim(uuid, text, text, text) to authenticated;

-- Admin: approve or turn down a claim. The person hears back either way.
create or replace function public.review_place_claim(p_claim uuid, p_approve boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  c public.place_claims;
  pname text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.place_claims where id = p_claim;
  if not found then return; end if;
  update public.place_claims
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = auth.uid()
   where id = p_claim;
  select name into pname from public.places where id = c.place_id;
  perform public.push_notify(
    c.user_id, 'claim',
    case when p_approve then 'You now run ' || coalesce(pname, 'your place') || ' on FUNKY ✓'
         else 'Your claim for ' || coalesce(pname, 'that place') || ' wasn''t approved' end,
    case when p_approve then 'Post your events, add pictures and set a deal from its page.'
         else 'If it''s yours, message the FUNKY team and we''ll sort it out.' end,
    jsonb_build_object('place_id', c.place_id));
end;
$$;

grant execute on function public.review_place_claim(uuid, boolean) to authenticated;

-- ---- 2) Owners' events are verified right away -------------------------------

alter table public.places add column if not exists official boolean not null default false;

create or replace function public.owner_event_autoverify()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.official := false;
  if new.host_place_id is not null and new.by_uid = auth.uid() and public.is_place_owner(new.host_place_id) then
    new.admin_verified := true;
    new.official := true;
  end if;
  return new;
end;
$$;

revoke all on function public.owner_event_autoverify() from public, anon, authenticated;

drop trigger if exists owner_event_autoverify on public.places;
create trigger owner_event_autoverify
  before insert on public.places
  for each row execute function public.owner_event_autoverify();

drop policy if exists "Add a place as yourself" on public.places;
create policy "Add a place as yourself"
  on public.places for insert to authenticated
  with check (
    auth.uid() = by_uid
    and not public.is_banned()
    and (
      admin_verified = false
      or public.is_admin()
      or (host_place_id is not null and public.is_place_owner(host_place_id))
    )
  );

-- ---- 3) Owners' pictures go live -----------------------------------------------

create or replace function public.suggest_place_photo(p_place uuid, p_url text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return '!Sign in to add a picture.'; end if;
  if public.is_banned() then return '!Your account can''t add pictures.'; end if;
  if p_url is null or length(p_url) < 10 or length(p_url) > 600 then return '!Bad picture.'; end if;
  if not exists (select 1 from public.places where id = p_place) then
    return '!That place isn''t around anymore.';
  end if;

  -- An admin's picture, or the owner's own picture of their place, goes live.
  if public.is_admin() or public.is_place_owner(p_place) then
    update public.places set photo_url = p_url, photo_credit = null where id = p_place;
    return 'approved';
  end if;

  if (select count(*) from public.place_photo_suggestions
       where user_id = uid and created_at > now() - interval '1 day') >= 5 then
    return '!That''s enough pictures for today — try again tomorrow.';
  end if;

  -- A newer suggestion replaces your earlier waiting one for this place.
  delete from public.place_photo_suggestions
   where place_id = p_place and user_id = uid and status = 'pending';
  insert into public.place_photo_suggestions (place_id, user_id, url) values (p_place, uid, p_url);
  return 'pending';
end;
$$;

grant execute on function public.suggest_place_photo(uuid, text) to authenticated;

-- ---- 4) The deal box ---------------------------------------------------------------

alter table public.places add column if not exists deal text;
alter table public.places add column if not exists deal_updated_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'places_deal_len') then
    alter table public.places add constraint places_deal_len check (deal is null or char_length(deal) <= 140);
  end if;
end;
$$;

-- Owner or admin sets (or, with null/empty, clears) the deal. Returns an
-- error starting with '!' or 'ok'.
create or replace function public.set_place_deal(p_place uuid, p_deal text)
returns text
language plpgsql
security definer set search_path = public
as $$
begin
  if not (public.is_admin() or public.is_place_owner(p_place)) then
    return '!Only the owner can change this.';
  end if;
  update public.places
     set deal = left(nullif(btrim(coalesce(p_deal, '')), ''), 140),
         deal_updated_at = now()
   where id = p_place;
  return 'ok';
end;
$$;

grant execute on function public.set_place_deal(uuid, text) to authenticated;
