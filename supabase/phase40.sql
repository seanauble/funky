-- ============================================================
-- Phase 40: Polls and places can be deleted again
--   A poll (or spot) shared in Live Chat with no words is a message that's
--   only the poll. Deleting the poll used to blank that message, which the
--   "a message can't be empty" rule refused — so the whole delete failed
--   (the poll came back, and tonight's cleanup of old places could stall).
--   Now those share-only messages are removed along with what they shared;
--   messages with words just lose the attachment.
-- Safe to run more than once. Needs phase 33.
-- ============================================================

create or replace function public.drop_empty_poll_shares()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  delete from public.chat_messages
   where poll_id = old.id
     and char_length(coalesce(text, '')) = 0
     and gif_url is null
     and place_id is null;
  return old;
end;
$$;

revoke all on function public.drop_empty_poll_shares() from public, anon, authenticated;

drop trigger if exists polls_drop_empty_shares on public.polls;
create trigger polls_drop_empty_shares
  before delete on public.polls
  for each row execute function public.drop_empty_poll_shares();

create or replace function public.drop_empty_place_shares()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  delete from public.chat_messages
   where place_id = old.id
     and char_length(coalesce(text, '')) = 0
     and gif_url is null
     and poll_id is null;
  return old;
end;
$$;

revoke all on function public.drop_empty_place_shares() from public, anon, authenticated;

drop trigger if exists places_drop_empty_shares on public.places;
create trigger places_drop_empty_shares
  before delete on public.places
  for each row execute function public.drop_empty_place_shares();
