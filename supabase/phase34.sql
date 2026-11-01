-- ============================================================
-- Phase 34: GIFs in direct messages and group chats.
-- Safe to run more than once. Needs phases 2, 7, 11.
-- ============================================================

alter table public.messages add column if not exists gif_url text;
alter table public.group_messages add column if not exists gif_url text;

do $$
declare
  c record;
begin
  if not exists (select 1 from pg_constraint where conname = 'messages_gif_url_ok') then
    alter table public.messages add constraint messages_gif_url_ok
      check (gif_url is null or (char_length(gif_url) <= 400 and gif_url ~ '^https://(media[0-9]*|i)\.giphy\.com/'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'group_messages_gif_url_ok') then
    alter table public.group_messages add constraint group_messages_gif_url_ok
      check (gif_url is null or (char_length(gif_url) <= 400 and gif_url ~ '^https://(media[0-9]*|i)\.giphy\.com/'));
  end if;
  -- A group message can be just a GIF: swap the old "words or a photo"
  -- rule for one that also counts a GIF.
  for c in
    select conname from pg_constraint
     where conrelid = 'public.group_messages'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%media_path IS NOT NULL%'
       and pg_get_constraintdef(oid) not like '%gif_url%'
  loop
    execute format('alter table public.group_messages drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'group_messages_has_content') then
    alter table public.group_messages add constraint group_messages_has_content
      check (char_length(text) > 0 or media_path is not null or gif_url is not null);
  end if;
end;
$$;

-- Notifications say "Sent you a GIF" instead of an empty line.
create or replace function public.notify_dm()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  who text;
  preview text;
begin
  who := public.notif_handle(new.sender_id);
  if new.media_path is not null and coalesce(new.text, '') = '' then
    preview := case when new.media_type = 'video' then 'Sent you a video' else 'Sent you a photo' end;
  elsif new.gif_url is not null and coalesce(new.text, '') = '' then
    preview := 'Sent you a GIF';
  else
    preview := left(coalesce(new.text, ''), 120);
  end if;
  perform public.push_notify(
    new.recipient_id, 'dm', '@' || who, preview,
    jsonb_build_object('from', new.sender_id, 'message_id', new.id)
  );
  return new;
end;
$$;

create or replace function public.notify_group_message()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  nm text;
  who text;
  preview text;
  m record;
begin
  select name into nm from public.group_chats where id = new.group_id;
  who := public.notif_handle(new.sender_id);
  if new.media_path is not null and char_length(new.text) = 0 then
    preview := '@' || who || ' sent a ' || (case when new.media_type = 'video' then 'video' else 'photo' end);
  elsif new.gif_url is not null and char_length(new.text) = 0 then
    preview := '@' || who || ' sent a GIF';
  else
    preview := '@' || who || ': ' || left(new.text, 100);
  end if;
  for m in select user_id from public.group_members where group_id = new.group_id and user_id <> new.sender_id loop
    delete from public.notifications
     where user_id = m.user_id and kind = 'group' and read_at is null and data ->> 'group_id' = new.group_id::text;
    perform public.push_notify(m.user_id, 'group', coalesce(nm, 'Group chat'), preview,
      jsonb_build_object('group_id', new.group_id, 'message_id', new.id));
  end loop;
  return new;
end;
$$;
