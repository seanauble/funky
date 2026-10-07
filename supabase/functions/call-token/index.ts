// FUNKY — call-token Edge Function.
//
// The app calls this when a video call starts or is answered. It checks that
// the person asking is really one of the two people on that call (and that
// the call is still live), then hands back a short-lived LiveKit token for a
// private room named after the call. Nobody else can get a token for it.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   LIVEKIT_URL         wss://<your-project>.livekit.cloud
//   LIVEKIT_API_KEY     from LiveKit Cloud → Settings → Keys
//   LIVEKIT_API_SECRET  same place
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// Deploy with "Verify JWT" turned OFF — this function checks the caller's
// login itself (below), which also avoids gateway problems with Supabase's
// newer signing keys.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function b64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// A LiveKit access token is a plain HS256 JWT.
async function liveKitToken(
  apiKey: string,
  apiSecret: string,
  room: string,
  identity: string,
  name: string,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    iss: apiKey,
    sub: identity,
    name,
    nbf: now - 5,
    exp: now + 2 * 60 * 60,
    video: {
      room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
    },
  };
  const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(apiSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return `${data}.${b64url(sig)}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  const url = Deno.env.get("LIVEKIT_URL");
  const apiKey = Deno.env.get("LIVEKIT_API_KEY");
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET");
  if (!url || !apiKey || !apiSecret) {
    return json({ error: "Video calling isn't switched on yet — the LiveKit keys haven't been added." }, 500);
  }

  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!bearer) return json({ error: "Log in first." }, 401);
  const { data: auth, error: authError } = await admin.auth.getUser(bearer);
  if (authError || !auth?.user) return json({ error: "Log in again, then retry." }, 401);
  const uid = auth.user.id;

  let callId = "";
  let groupCallId = "";
  try {
    const body = await req.json();
    callId = String(body?.call_id ?? "");
    groupCallId = String(body?.group_call_id ?? "");
  } catch (_) {
    return json({ error: "Missing call." }, 400);
  }
  if (!callId && !groupCallId) return json({ error: "Missing call." }, 400);

  const { data: profile } = await admin.from("profiles").select("handle").eq("id", uid).maybeSingle();
  const name = profile?.handle ?? "friend";

  // ---- A call inside a group chat: any member can join while it's live ----
  if (groupCallId) {
    const { data: gcall } = await admin
      .from("group_calls")
      .select("id, group_id, status, last_active_at")
      .eq("id", groupCallId)
      .maybeSingle();
    if (!gcall) return json({ error: "That call isn't available." }, 404);
    const { data: member } = await admin
      .from("group_members")
      .select("user_id")
      .eq("group_id", gcall.group_id)
      .eq("user_id", uid)
      .maybeSingle();
    if (!member) return json({ error: "You're not in that group." }, 403);
    const idleSec = (Date.now() - new Date(gcall.last_active_at).getTime()) / 1000;
    if (gcall.status !== "active" || idleSec > 120) return json({ error: "That call already ended." }, 409);
    const gtoken = await liveKitToken(apiKey, apiSecret, `gcall_${gcall.id}`, uid, name);
    return json({ url, token: gtoken });
  }

  // ---- A one-to-one call ----
  const { data: call } = await admin
    .from("calls")
    .select("id, caller_id, callee_id, status, created_at")
    .eq("id", callId)
    .maybeSingle();
  if (!call || (call.caller_id !== uid && call.callee_id !== uid)) {
    return json({ error: "That call isn't available." }, 403);
  }

  // The caller joins while it rings; the person being called joins once
  // they've answered. Anything finished is closed.
  const ageSec = (Date.now() - new Date(call.created_at).getTime()) / 1000;
  const isCaller = call.caller_id === uid;
  const ok = (isCaller && call.status === "ringing" && ageSec < 90) || call.status === "accepted";
  if (!ok) return json({ error: "That call already ended." }, 409);

  const token = await liveKitToken(apiKey, apiSecret, `call_${call.id}`, uid, name);
  return json({ url, token });
});
