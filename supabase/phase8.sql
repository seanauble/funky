-- ============================================================
-- PHASE 8 — @mentions in the live chat.
-- Typing @name in the live chat notifies that person (in the app and as
-- an iPhone push, through the same notifications table as phase 7).
-- Safe to re-run. Needs phase 7 first.
-- ============================================================

alter table public.notification_prefs
  add column if not exists mention_on boolean not null default true;

-- Same as phase 7's push_notify, plus the 'mention' kind.
create or replace function public.push_notify(
  target uuid, k text, t text, b text, d jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  wanted boolean;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.profiles where id = target) then return; end if;

  select case k
           when 'dm' then dm_on
           when 'friend' then friend_on
           when 'place' then place_on
           when 'report' then report_on
           when 'mention' then mention_on
           else true
         end
    into wanted
    from public.notification_prefs
   where user_id = target;
  if found and not coalesce(wanted, true) then return; end if;

  delete from public.notifications where user_id = target and created_at < now() - interval '30 days';

  insert into public.notifications (user_id, kind, title, body, data)
  values (target, k, t, b, coalesce(d, '{}'::jsonb));
end;
$$;

revoke all on function public.push_notify(uuid, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public.notify_chat_mentions()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  author uuid := coalesce(new.sender_id, auth.uid());
  title text;
  h text;
  target uuid;
  sent integer := 0;
begin
  if new.text is null or position('@' in new.text) = 0 then
    return new;
  end if;

  if new.anon or new.sender_id is null then
    title := 'Someone mentioned you in live chat';
  else
    title := '@' || public.notif_handle(new.sender_id) || ' mentioned you';
  end if;

  for h in
    select distinct lower(m[1])
      from regexp_matches(new.text, '(?<![A-Za-z0-9_])@([A-Za-z0-9_]{2,30})', 'g') as m
  loop
    exit when sent >= 5;
    select id into target from public.profiles where lower(handle) = h;
    if target is not null and target is distinct from author then
      perform public.push_notify(
        target, 'mention', title, left(new.text, 120),
        jsonb_build_object('chat', true, 'message_id', new.id)
      );
      sent := sent + 1;
    end if;
    target := null;
  end loop;

  return new;
end;
$$;

revoke all on function public.notify_chat_mentions() from public, anon, authenticated;

drop trigger if exists notify_chat_mentions on public.chat_messages;
create trigger notify_chat_mentions after insert on public.chat_messages
  for each row execute procedure public.notify_chat_mentions();
