// FUNKY — send-push Edge Function.
//
// A Supabase Database Webhook calls this every time a row is INSERTed into
// public.notifications (see supabase/phase7.sql). It looks up that person's
// phones in public.device_tokens and delivers the notification through
// Apple's push service (APNs), signed with your APNs auth key (.p8).
//
// Secrets this function reads (Supabase → Edge Functions → Secrets):
//   APNS_KEY_P8      full contents of the AuthKey_XXXXXXXXXX.p8 file
//   APNS_KEY_ID      the 10-character Key ID
//   APNS_TEAM_ID     your 10-character Apple Developer Team ID
//   APNS_BUNDLE_ID   optional, defaults to com.funkyapp.funky
//   APNS_PRODUCTION  optional, "true" (default; TestFlight + App Store) or "false"
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.funkyapp.funky";
const PRODUCTION = (Deno.env.get("APNS_PRODUCTION") ?? "true").toLowerCase() !== "false";
const APNS_HOST = PRODUCTION ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";

function b64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : new Uint8Array(input);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cachedKey: CryptoKey | null = null;
let cachedJwt: { token: string; at: number } | null = null;

async function signingKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  const pem = (Deno.env.get("APNS_KEY_P8") ?? "")
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  if (!pem) throw new Error("APNS_KEY_P8 secret is missing");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  cachedKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return cachedKey;
}

// Apple wants a fresh-ish token: reuse one for up to 40 minutes.
async function apnsJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.at < 40 * 60) return cachedJwt.token;
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  if (!keyId || !teamId) throw new Error("APNS_KEY_ID / APNS_TEAM_ID secret is missing");
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: now }));
  const data = new TextEncoder().encode(`${header}.${claims}`);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(),
    data,
  );
  const token = `${header}.${claims}.${b64url(sig)}`;
  cachedJwt = { token, at: now };
  return token;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload?.record;
    if (!record?.user_id) {
      return new Response("no record", { status: 200 });
    }

    const { data: tokens } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", record.user_id);
    if (!tokens || tokens.length === 0) {
      return new Response("no devices", { status: 200 });
    }

    // The red number on the app icon = unread notifications.
    const { count } = await supabase
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .eq("user_id", record.user_id)
      .is("read_at", null);

    const body = JSON.stringify({
      aps: {
        alert: { title: record.title || "FUNKY", body: record.body || "" },
        sound: "default",
        badge: count ?? 1,
      },
      kind: record.kind,
      data: record.data ?? {},
    });

    const jwt = await apnsJwt();
    const results: string[] = [];
    for (const { token } of tokens) {
      const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": BUNDLE_ID,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body,
      });
      if (res.status === 200) {
        results.push("ok");
        continue;
      }
      const text = await res.text();
      results.push(`${res.status} ${text}`);
      // Dead token (app deleted / token rotated): stop sending to it.
      if (res.status === 410 || text.includes("BadDeviceToken") || text.includes("Unregistered")) {
        await supabase.from("device_tokens").delete().eq("token", token);
      }
    }
    return new Response(JSON.stringify(results), { status: 200 });
  } catch (e) {
    console.error("send-push failed", e);
    return new Response(String(e), { status: 500 });
  }
});
