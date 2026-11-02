-- ============================================================
-- Phase 42: Refer friends, get a free night out
--   * Everyone gets a short invite code.
--   * A new account (under 14 days old) can enter who invited them, once.
--   * A friend counts once their account is a day old and they've done one
--     real thing (posted, marked going, added a friend). That stops fake
--     sign-ups from counting.
--   * Each friend who counts: +100 points for you, +50 for them.
--   * Every 5 friends who count: a FUNKY reward pass. Bars and clubs that
--     run their page on FUNKY say what they give for it (free cover, skip
--     the line, ...) and the pass is used once, in front of staff.
-- Safe to run more than once. Needs phases 2, 11, 15, 29, 33, 41.
-- ============================================================

-- ---- Codes ----------------------------------------------------------------------

create table if not exists public.referral_codes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9]{4,12}$'),
  created_at timestamptz not null default now()
);

alter table public.referral_codes enable row level security;
grant select on public.referral_codes to authenticated;

drop policy if exists "See your own invite code" on public.referral_codes;
create policy "See your own invite code" on public.referral_codes for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---- Who invited who -----------------------------------------------------------------

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles (id) on delete cascade,
  referred_id uuid not null unique references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  qualified_at timestamptz,
  check (referrer_id <> referred_id)
);

create index if not exists referrals_referrer_idx on public.referrals (referrer_id, qualified_at);

alter table public.referrals enable row level security;
grant select on public.referrals to authenticated;

drop policy if exists "See your own referrals" on public.referrals;
create policy "See your own referrals" on public.referrals for select to authenticated
  using (referrer_id = auth.uid() or referred_id = auth.uid() or public.is_admin());

-- ---- Reward passes ----------------------------------------------------------------------

create table if not exists public.referral_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  redeemed_at timestamptz,
  redeemed_place_id uuid references public.places (id) on delete set null,
  redeemed_reward text
);

create index if not exists referral_rewards_user_idx on public.referral_rewards (user_id, created_at);
create index if not exists referral_rewards_place_idx on public.referral_rewards (redeemed_place_id);

alter table public.referral_rewards enable row level security;
grant select on public.referral_rewards to authenticated;

-- Yours, and the ones used at a place you run (so owners can see how many
-- people FUNKY brought in).
drop policy if exists "See your rewards and ones used at your place" on public.referral_rewards;
create policy "See your rewards and ones used at your place" on public.referral_rewards for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or (redeemed_place_id is not null and public.is_place_owner(redeemed_place_id))
  );

-- What a bar or club gives for a pass. Null = not taking part.
alter table public.places add column if not exists reward text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'places_reward_len') then
    alter table public.places add constraint places_reward_len check (reward is null or char_length(reward) <= 60);
  end if;
end;
$$;

-- ---- Helpers (server only) ------------------------------------------------------------

-- Points on profiles are admin-only, so step out of the caller's identity
-- just for this one update, then step back in.
create or replace function public.referral_add_points(p_user uuid, p_points integer)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  saved_sub text := current_setting('request.jwt.claim.sub', true);
  saved_claims text := current_setting('request.jwt.claims', true);
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  update public.profiles set bonus_points = bonus_points + p_points where id = p_user;
  perform set_config('request.jwt.claim.sub', coalesce(saved_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(saved_claims, ''), true);
end;
$$;

revoke all on function public.referral_add_points(uuid, integer) from public, anon, authenticated;

-- Makes the code for a user if they don't have one yet.
create or replace function public.referral_code_for(p_user uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  have text;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
  tries integer := 0;
begin
  select code into have from public.referral_codes where user_id = p_user;
  if have is not null then return have; end if;
  loop
    tries := tries + 1;
    c := '';
    for i in 1 .. (case when tries > 20 then 8 else 6 end) loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::integer, 1);
    end loop;
    begin
      insert into public.referral_codes (user_id, code) values (p_user, c);
      return c;
    exception when unique_violation then
      select code into have from public.referral_codes where user_id = p_user;
      if have is not null then return have; end if;
      if tries > 40 then raise; end if;
    end;
  end loop;
end;
$$;

revoke all on function public.referral_code_for(uuid) from public, anon, authenticated;

-- Checks whether a waiting referral counts yet, and pays out if so.
create or replace function public.referral_try_qualify(p_ref uuid)
returns boolean
language plpgsql
security definer set search_path = public
as $$
declare
  r public.referrals;
  joined timestamptz;
  anon boolean;
  is_banned_user boolean;
  active boolean;
  counted integer;
  passes integer;
  due integer;
  new_handle text;
  ref_handle text;
begin
  select * into r from public.referrals where id = p_ref for update;
  if not found or r.qualified_at is not null then return false; end if;

  select created_at, coalesce(banned, false), handle into joined, is_banned_user, new_handle
    from public.profiles where id = r.referred_id;
  if joined is null or is_banned_user then return false; end if;
  if joined > now() - interval '1 day' then return false; end if;

  select coalesce(is_anonymous, false) into anon from auth.users where id = r.referred_id;
  if coalesce(anon, true) then return false; end if;

  active := exists (select 1 from public.stories where uid = r.referred_id)
         or exists (select 1 from public.posts where uid = r.referred_id)
         or exists (select 1 from public.place_rsvps where user_id = r.referred_id)
         or exists (select 1 from public.friendships
                     where status = 'accepted' and (requester_id = r.referred_id or addressee_id = r.referred_id));
  if not active then return false; end if;

  update public.referrals set qualified_at = now() where id = r.id;

  perform public.referral_add_points(r.referrer_id, 100);
  perform public.referral_add_points(r.referred_id, 50);

  select handle into ref_handle from public.profiles where id = r.referrer_id;
  select count(*) into counted from public.referrals where referrer_id = r.referrer_id and qualified_at is not null;
  select count(*) into passes from public.referral_rewards where user_id = r.referrer_id;
  due := counted / 5 - passes;

  perform public.push_notify(
    r.referred_id, 'referral',
    '+50 points for joining with @' || coalesce(ref_handle, 'a friend') || '''s code',
    'Invite your own friends — every 5 who join gets you a free night out.',
    '{}'::jsonb);

  if due > 0 then
    for i in 1 .. due loop
      insert into public.referral_rewards (user_id) values (r.referrer_id);
    end loop;
    perform public.push_notify(
      r.referrer_id, 'referral',
      'You unlocked a FUNKY reward 🎁',
      '@' || coalesce(new_handle, 'your friend') || ' made it ' || counted || ' friends. Show your pass at a FUNKY Rewards bar.',
      '{}'::jsonb);
  else
    perform public.push_notify(
      r.referrer_id, 'referral',
      '@' || coalesce(new_handle, 'Your friend') || ' counts! ' || (counted % 5) || ' of 5 friends',
      '+100 points. ' || (5 - counted % 5) || ' more for a free night out.',
      '{}'::jsonb);
  end if;
  return true;
end;
$$;

revoke all on function public.referral_try_qualify(uuid) from public, anon, authenticated;

-- ---- What the app calls --------------------------------------------------------------

-- Enter who invited you (their code or @handle). Returns 'ok' or an error
-- starting with '!'.
create or replace function public.use_referral_code(p_code text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  raw text := btrim(coalesce(p_code, ''));
  them uuid;
  joined timestamptz;
  my_handle text;
begin
  if me is null or public.is_guest() then return '!Make an account first, then add who invited you.'; end if;
  if public.is_banned() then return '!Your account can''t do that.'; end if;
  if raw = '' then return '!Type their code or @username.'; end if;
  if exists (select 1 from public.referrals where referred_id = me) then
    return '!You already added who invited you.';
  end if;
  select created_at, handle into joined, my_handle from public.profiles where id = me;
  if joined is null or joined < now() - interval '14 days' then
    return '!Invite codes are only for new accounts (your first 2 weeks).';
  end if;

  select user_id into them from public.referral_codes where code = upper(raw);
  if them is null then
    select id into them from public.profiles where lower(handle) = lower(ltrim(raw, '@')) limit 1;
  end if;
  if them is null then return '!No one has that code — check it and try again.'; end if;
  if them = me then return '!That''s your own code.'; end if;
  if coalesce((select banned from public.profiles where id = them), false) then
    return '!That code doesn''t work anymore.';
  end if;
  -- No inviting each other back and forth.
  if exists (select 1 from public.referrals where referrer_id = me and referred_id = them) then
    return '!You invited them, so they can''t be the one who invited you.';
  end if;

  insert into public.referrals (referrer_id, referred_id) values (them, me)
  on conflict (referred_id) do nothing;
  if not found then return '!You already added who invited you.'; end if;

  perform public.push_notify(
    them, 'referral',
    '@' || coalesce(my_handle, 'someone') || ' joined FUNKY with your code 🎉',
    'They count toward your free night out once they''re active.',
    jsonb_build_object('from', me));
  return 'ok';
end;
$$;

grant execute on function public.use_referral_code(text) to authenticated;

-- Everything for the invite screen: your code, who you brought in, your
-- passes, and whether you can still add who invited you. Also checks any
-- waiting referrals (yours and the one that brought you in).
create or replace function public.referral_status()
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  r record;
  joined timestamptz;
  my_code text;
begin
  if me is null then return null; end if;

  for r in
    select id from public.referrals
     where qualified_at is null and (referrer_id = me or referred_id = me)
     order by created_at
     limit 50
  loop
    perform public.referral_try_qualify(r.id);
  end loop;

  if not public.is_guest() then my_code := public.referral_code_for(me); end if;
  select created_at into joined from public.profiles where id = me;

  return jsonb_build_object(
    'code', my_code,
    'per_reward', 5,
    'invited_by', (select referrer_id from public.referrals where referred_id = me),
    'invited_by_counts', (select qualified_at is not null from public.referrals where referred_id = me),
    'can_enter_code',
      not public.is_guest()
      and not exists (select 1 from public.referrals where referred_id = me)
      and coalesce(joined > now() - interval '14 days', false),
    'invited', coalesce((
      select jsonb_agg(jsonb_build_object('uid', x.referred_id, 'at', x.created_at, 'counted_at', x.qualified_at)
                       order by x.created_at desc)
        from public.referrals x where x.referrer_id = me), '[]'::jsonb),
    'rewards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'at', w.created_at, 'used_at', w.redeemed_at,
               'place_id', w.redeemed_place_id, 'reward', w.redeemed_reward)
             order by w.created_at desc)
        from public.referral_rewards w where w.user_id = me), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.referral_status() to authenticated;

-- Use a pass at a FUNKY Rewards bar. Do it in front of staff — it's one
-- time only. Returns the reward text, or an error starting with '!'.
create or replace function public.redeem_referral_reward(p_reward uuid, p_place uuid)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  w public.referral_rewards;
  pl record;
  who text;
  owner_row record;
begin
  if me is null then return '!Sign in first.'; end if;
  if public.is_banned() then return '!Your account can''t do that.'; end if;
  select * into w from public.referral_rewards where id = p_reward and user_id = me for update;
  if not found then return '!That pass isn''t yours.'; end if;
  if w.redeemed_at is not null then return '!That pass was already used.'; end if;
  select id, name, reward into pl from public.places where id = p_place;
  if not found then return '!That place isn''t around anymore.'; end if;
  if coalesce(btrim(pl.reward), '') = '' then return '!That place isn''t taking FUNKY rewards.'; end if;

  update public.referral_rewards
     set redeemed_at = now(), redeemed_place_id = p_place, redeemed_reward = pl.reward
   where id = w.id;

  select handle into who from public.profiles where id = me;
  for owner_row in
    select user_id from public.place_claims where place_id = p_place and status = 'approved' and user_id <> me
  loop
    perform public.push_notify(
      owner_row.user_id, 'reward_used',
      'A FUNKY reward was just used at ' || coalesce(pl.name, 'your place'),
      '@' || coalesce(who, 'someone') || ' · ' || pl.reward,
      jsonb_build_object('place_id', p_place));
  end loop;
  return pl.reward;
end;
$$;

grant execute on function public.redeem_referral_reward(uuid, uuid) to authenticated;

-- Owner or admin: what this place gives for a FUNKY reward pass (empty to
-- stop taking part). Returns 'ok' or an error starting with '!'.
create or replace function public.set_place_reward(p_place uuid, p_reward text)
returns text
language plpgsql
security definer set search_path = public
as $$
begin
  if not (public.is_admin() or public.is_place_owner(p_place)) then
    return '!Only the owner can change this.';
  end if;
  update public.places
     set reward = left(nullif(btrim(coalesce(p_reward, '')), ''), 60)
   where id = p_place;
  return 'ok';
end;
$$;

grant execute on function public.set_place_reward(uuid, text) to authenticated;
