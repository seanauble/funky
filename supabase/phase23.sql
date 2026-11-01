-- ============================================================
-- Phase 23: +1,000 Funky Points when your picture for a place is approved.
-- Paid once per person per place (a second approved picture of the same
-- spot doesn't pay again). The points arrive as bonus points, so the
-- person's app picks them up live. Safe to run more than once.
-- ============================================================

create or replace function public.review_place_photo(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  s public.place_photo_suggestions;
  pname text;
  first_for_place boolean;
begin
  if not public.is_admin() then return; end if;
  select * into s from public.place_photo_suggestions where id = p_id and status = 'pending';
  if not found then return; end if;
  select name into pname from public.places where id = s.place_id;

  if p_approve then
    first_for_place := not exists (
      select 1 from public.place_photo_suggestions
      where user_id = s.user_id and place_id = s.place_id and status = 'approved' and id <> s.id
    );
    update public.places set photo_url = s.url, photo_credit = null where id = s.place_id;
    update public.place_photo_suggestions set status = 'approved' where id = s.id;
    if first_for_place then
      update public.profiles set bonus_points = bonus_points + 1000 where id = s.user_id;
      perform public.push_notify(s.user_id, 'photo', 'Your picture was approved — +1,000 points!',
        'Your picture for ' || coalesce(pname, 'the place') || ' is live. 1,000 Funky Points added.',
        jsonb_build_object('place_id', s.place_id));
    else
      perform public.push_notify(s.user_id, 'photo', 'Your picture was approved',
        'Your picture for ' || coalesce(pname, 'the place') || ' is live.',
        jsonb_build_object('place_id', s.place_id));
    end if;
  else
    update public.place_photo_suggestions set status = 'rejected' where id = s.id;
    perform public.push_notify(s.user_id, 'photo', 'Picture not approved',
      'Your picture for ' || coalesce(pname, 'the place') || ' wasn''t approved.',
      jsonb_build_object('place_id', s.place_id));
  end if;
end;
$$;

grant execute on function public.review_place_photo(uuid, boolean) to authenticated;
