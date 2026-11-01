-- ============================================================
-- Phase 24: stories remember where they were posted, so an Area story
-- only shows to people within range of it (the app filters by your radius).
-- Safe to run more than once.
-- ============================================================

alter table public.stories add column if not exists lat double precision;
alter table public.stories add column if not exists lng double precision;
