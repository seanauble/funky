-- ============================================================
-- Phase 25: replying to a Story from the Story viewer ("swipe up")
-- sends a DM that remembers which Story it answered, so both people
-- see a small preview of it above the message in the chat.
-- Safe to run more than once.
-- ============================================================

alter table public.messages add column if not exists story_id uuid;
alter table public.messages add column if not exists story_text text;
alter table public.messages add column if not exists story_media_path text;
alter table public.messages add column if not exists story_is_video boolean not null default false;

-- Keep the snapshot small.
alter table public.messages drop constraint if exists messages_story_text_len;
alter table public.messages add constraint messages_story_text_len
  check (story_text is null or char_length(story_text) <= 200);

-- The two people in a story-reply DM can keep loading that Story's
-- picture for the preview, even after the 24 hours are up.
drop policy if exists "Read story media replied to in your DMs" on storage.objects;
create policy "Read story media replied to in your DMs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'stories'
    and exists (
      select 1 from public.messages m
      where m.story_media_path = name
        and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())
    )
  );

create index if not exists messages_story_media_path_idx
  on public.messages (story_media_path) where story_media_path is not null;
