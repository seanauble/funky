# FUNKY notifications — one-time setup

1. **SQL**: Supabase → SQL Editor → paste all of `RUN_ALL.sql` → Run (safe to re-run).
2. **Apple**: developer.apple.com → Certificates, Identifiers & Profiles
   - Identifiers → `com.funkyapp.funky` → tick **Push Notifications** → Save.
   - Keys → **+** → name "FUNKY push" → tick **Apple Push Notifications service (APNs)** → Continue → Register → **Download** the `.p8` (one chance) and note the **Key ID**. Your **Team ID** is under Membership details.
3. **Edge Function**: Supabase → Edge Functions → Deploy a new function → name `send-push` → paste `functions/send-push/index.ts` → Deploy.
4. **Secrets**: Edge Functions → Secrets: `APNS_KEY_P8` (the whole .p8 file text), `APNS_KEY_ID`, `APNS_TEAM_ID`.
5. **Webhook**: Database → Webhooks → Create: name `send-push`, table `notifications`, event **Insert**, type **Supabase Edge Functions**, function `send-push`.
6. Build with Codemagic → TestFlight. If signing complains about `aps-environment`, delete the old App Store provisioning profile for `com.funkyapp.funky` in the Apple portal and rebuild.
