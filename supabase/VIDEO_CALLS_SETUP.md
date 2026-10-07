# FUNKY video calls — one-time setup

Video calls run through LiveKit: one-to-one between friends (the camera button in a DM) and group video calls (the camera button in a group chat).

1. **LiveKit account**: sign up at livekit.io (LiveKit Cloud), create a project. In the project's **Settings → Keys** make a key. You'll have three values:
   the project URL (looks like `wss://something.livekit.cloud`), an API key, and an API secret.
2. **SQL**: Supabase → SQL Editor → paste all of `RUN_ALL.sql` → Run (includes phases 13 and 14).
3. **Edge Function**: Supabase → Edge Functions → Deploy a new function → name it exactly `call-token` → paste `functions/call-token/index.ts` → turn **Verify JWT OFF** → Deploy.
4. **Secrets**: Edge Functions → Secrets → add `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
5. Build with Codemagic → TestFlight. You need two phones (two accounts that are friends) to try a call.

Cost: LiveKit Cloud has a free allowance and charges beyond it — check their pricing page.
