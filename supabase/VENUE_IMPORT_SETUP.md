# Importing bars & clubs (free — OpenStreetMap, no Google)

One-time setup (about 3 minutes):

1. **Supabase → SQL Editor → New query** → paste `supabase/RUN_ALL.sql` → Run.
2. **Supabase → Edge Functions → Deploy a new function → Via Editor**
   - Name: `import-venues`
   - Paste all of `supabase/functions/import-venues/index.ts` → **Deploy**
   - Open it → **Settings** → turn **Verify JWT** OFF → Save.

(The `venue-photo` function is only for Google photos — you don't need it.)

Then in the app: **Settings → Admin panel → Review bars & clubs to add → Import bars & clubs.**

For each venue: tap **Add a photo** (library or camera), fix the name/address in
**Edit / note** if needed, then **Approve** — it goes live as a FUNKY-verified place.
Or **Deny**, or save a note for later under "Needs changes".

Run the import again any time; it only adds venues you haven't seen yet.
Venue list © OpenStreetMap contributors.
