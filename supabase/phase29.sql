-- ============================================================
-- Phase 29: Posts. A few photos and a caption, optionally tagged at a
-- place, with likes and comments. Everyone sees every post in their area
-- (the app shows the posts inside your radius). Unlike Stories, posts
-- don't disappear after 24 hours.
-- Guests can look but not post, like or comment. Posts can be reported
-- (they go to the same admin review list as reported Stories).
-- Safe to run more than once. Needs phases 15 (is_guest), 26 and 27.
-- ============================================================

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  uid uuid not null references public.profiles (id) on delete cascade,
  caption text not null default '' check (char_length(caption) <= 500),
  place_id text,
  place_name text check (place_name is null or char_length(place_name) <= 80),
  lat double precision not null,
  lng double precision not null,
  photo_paths text[] not null check (array_length(photo_paths, 1) between 1 and 5),
  created_at timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_uid_idx on public.posts (uid);

alter table public.posts enable row level security;
grant select, insert, delete on public.posts to authenticated;

drop policy if exists "See posts" on public.posts;
create policy "See posts" on public.posts for select to authenticated using (true);

drop policy if exists "Post as yourself" on public.posts;
create policy "Post as yourself" on public.posts for insert to authenticated
  with check (auth.uid() = uid and not public.is_banned() and not public.is_guest());

drop policy if exists "Delete your own post (admins any)" on public.posts;
create policy "Delete your own post (admins any)" on public.posts for delete to authenticated
  using (auth.uid() = uid or public.is_admin());

drop trigger if exists rate_limit_posts on public.posts;
create trigger rate_limit_posts before insert on public.posts
  for each row execute procedure public.rate_limit('uid', '86400', '10');

-- ---- Likes ------------------------------------------------------------

create table if not exists public.post_likes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_likes enable row level security;
grant select, insert, delete on public.post_likes to authenticated;

drop policy if exists "See post likes" on public.post_likes;
create policy "See post likes" on public.post_likes for select to authenticated using (true);

drop policy if exists "Like as yourself" on public.post_likes;
create policy "Like as yourself" on public.post_likes for insert to authenticated
  with check (auth.uid() = user_id and not public.is_banned() and not public.is_guest());

drop policy if exists "Unlike your own like" on public.post_likes;
create policy "Unlike your own like" on public.post_likes for delete to authenticated
  using (auth.uid() = user_id);

-- ---- Comments ---------------------------------------------------------

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  uid uuid not null references public.profiles (id) on delete cascade,
  text text not null check (char_length(btrim(text)) between 1 and 300),
  created_at timestamptz not null default now()
);

create index if not exists post_comments_post_idx on public.post_comments (post_id, created_at);

alter table public.post_comments enable row level security;
grant select, insert, delete on public.post_comments to authenticated;

drop policy if exists "See comments" on public.post_comments;
create policy "See comments" on public.post_comments for select to authenticated using (true);

drop policy if exists "Comment as yourself" on public.post_comments;
create policy "Comment as yourself" on public.post_comments for insert to authenticated
  with check (auth.uid() = uid and not public.is_banned() and not public.is_guest());

-- Your own comment, any comment on your own post, or an admin.
drop policy if exists "Delete a comment" on public.post_comments;
create policy "Delete a comment" on public.post_comments for delete to authenticated
  using (
    auth.uid() = uid
    or public.is_admin()
    or exists (select 1 from public.posts p where p.id = post_id and p.uid = auth.uid())
  );

drop trigger if exists rate_limit_post_comments on public.post_comments;
create trigger rate_limit_post_comments before insert on public.post_comments
  for each row execute procedure public.rate_limit('uid', '60', '8');

-- Tell the poster when someone comments.
create or replace function public.notify_post_comment()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  owner uuid;
  who text;
begin
  select uid into owner from public.posts where id = new.post_id;
  if owner is null or owner = new.uid then
    return new;
  end if;
  select handle into who from public.profiles where id = new.uid;
  perform public.push_notify(
    owner, 'post_comment', '@' || coalesce(who, 'someone') || ' commented on your post',
    left(new.text, 120),
    jsonb_build_object('post_id', new.post_id, 'from', new.uid));
  return new;
end;
$$;

drop trigger if exists post_comments_notify on public.post_comments;
create trigger post_comments_notify
  after insert on public.post_comments
  for each row execute function public.notify_post_comment();

-- ---- Photos (public bucket: posts are meant to be seen) -----------------

insert into storage.buckets (id, name, public)
values ('posts', 'posts', true)
on conflict (id) do update set public = true;

drop policy if exists "Upload your own post photos" on storage.objects;
create policy "Upload your own post photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'posts'
    and (storage.foldername(name)) [1] = auth.uid()::text
    and not public.is_guest()
  );

drop policy if exists "Read post photos" on storage.objects;
create policy "Read post photos"
  on storage.objects for select to authenticated
  using (bucket_id = 'posts');

drop policy if exists "Delete your own post photos" on storage.objects;
create policy "Delete your own post photos"
  on storage.objects for delete to authenticated
  using (bucket_id = 'posts' and ((storage.foldername(name)) [1] = auth.uid()::text or public.is_admin()));

-- ---- Reporting a post (same admin list as Story reports) ----------------

alter table public.story_reports add column if not exists post_id uuid references public.posts (id) on delete set null;
alter table public.story_reports add column if not exists kind text not null default 'story';
alter table public.story_reports drop constraint if exists story_reports_kind_check;
alter table public.story_reports add constraint story_reports_kind_check check (kind in ('story', 'post'));

create unique index if not exists post_report_one_open
  on public.story_reports (reporter_id, post_id) where status = 'open' and post_id is not null;

create or replace function public.report_post(p_post uuid, p_reason text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r text := left(btrim(coalesce(p_reason, '')), 80);
  p public.posts%rowtype;
  rid uuid;
  who text;
  a record;
begin
  if uid is null then return 'Sign in to report a post.'; end if;
  if public.is_banned() then return 'Your account can''t send reports.'; end if;
  if char_length(r) < 2 then return 'Pick a reason.'; end if;
  select * into p from public.posts where id = p_post;
  if not found then return 'That post isn''t up anymore.'; end if;
  if p.uid = uid then return 'That''s your own post.'; end if;
  if exists (select 1 from public.story_reports
              where reporter_id = uid and post_id = p_post and status = 'open') then
    return 'You already reported this post. The FUNKY team will take a look.';
  end if;
  if (select count(*) from public.story_reports
       where reporter_id = uid and created_at > now() - interval '1 day') >= 15 then
    return 'That''s a lot of reports for one day. Try again tomorrow.';
  end if;

  insert into public.story_reports (
    kind, post_id, reporter_id, poster_id, reason,
    story_text, story_media_path, story_is_video, story_anon, story_place_name, story_created_at)
  values (
    'post', p.id, uid, p.uid, r,
    left(p.caption, 300), p.photo_paths[1], false, false, p.place_name, p.created_at)
  returning id into rid;

  if (select count(*) from public.story_reports where post_id = p.id and status = 'open') = 1 then
    select handle into who from public.profiles where id = p.uid;
    for a in
      select pr.id from public.profiles pr
       where pr.is_admin
          or pr.id in (select u.id from auth.users u where lower(u.email) = 'seanauble@icloud.com')
    loop
      if a.id <> uid then
        perform public.push_notify(
          a.id, 'story_report', 'Post reported',
          '@' || coalesce(who, 'someone') || '''s post was reported: ' || r,
          jsonb_build_object('report_id', rid, 'post_id', p.id));
      end if;
    end loop;
  end if;
  return null;
end;
$$;

grant execute on function public.report_post(uuid, text) to authenticated;

-- Admin: close a report (and the others on the same Story/post).
-- p_remove = true also deletes that Story or post and tells the poster.
create or replace function public.resolve_story_report(p_id uuid, p_remove boolean default false)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  rep public.story_reports%rowtype;
begin
  if not public.is_admin() then return 'Admins only.'; end if;
  select * into rep from public.story_reports where id = p_id;
  if not found then return 'That report is gone.'; end if;

  update public.story_reports
     set status = 'resolved',
         outcome = case when p_remove then 'removed' else 'dismissed' end
   where status = 'open'
     and (id = p_id
          or (rep.story_id is not null and story_id = rep.story_id)
          or (rep.post_id is not null and post_id = rep.post_id));

  if p_remove then
    if rep.story_id is not null then
      delete from public.stories where id = rep.story_id;
    end if;
    if rep.post_id is not null then
      delete from public.posts where id = rep.post_id;
    end if;
    if rep.poster_id is not null then
      perform public.push_notify(
        rep.poster_id, 'moderation',
        case when rep.kind = 'post' then 'Your post was removed' else 'Your story was removed' end,
        'One of your ' || case when rep.kind = 'post' then 'posts' else 'stories' end
          || ' broke the FUNKY community rules (' || rep.reason || ') and was taken down.',
        '{}'::jsonb);
    end if;
  end if;
  return null;
end;
$$;

grant execute on function public.resolve_story_report(uuid, boolean) to authenticated;

-- ---- Live updates -------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['posts', 'post_likes', 'post_comments'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
