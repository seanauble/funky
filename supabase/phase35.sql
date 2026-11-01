-- ============================================================
-- Phase 35: Live Chat reach.
--   Each Live Chat message remembers how far its sender's radius reached
--   when they sent it. The app shows a message to anyone inside their own
--   radius OR inside the sender's reach, so two people with different
--   radiuses still see each other when either circle covers the other.
--   Only admins can reach past 50 miles.
-- Safe to run more than once. Needs phase 2.
-- ============================================================

alter table public.chat_messages add column if not exists reach_miles integer;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chat_messages_reach_ok') then
    alter table public.chat_messages add constraint chat_messages_reach_ok
      check (reach_miles is null or reach_miles between 1 and 5000);
  end if;
end;
$$;

create or replace function public.chat_reach_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.reach_miles is not null and new.reach_miles > 50 and not public.is_admin() then
    new.reach_miles := 50;
  end if;
  return new;
end;
$$;

drop trigger if exists chat_reach_guard on public.chat_messages;
create trigger chat_reach_guard before insert on public.chat_messages
  for each row execute function public.chat_reach_guard();
