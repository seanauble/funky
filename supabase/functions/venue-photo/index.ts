// FUNKY — venue-photo Edge Function.
//
// Shows a Google Places photo for an imported venue. The app loads
//   <project>/functions/v1/venue-photo?ref=places/…/photos/…&w=800
// and this redirects to the actual image. Photos aren't copied or stored
// (Google's rules); only refs that belong to an imported venue are served,
// so nobody can use this to run up the Google bill.
//
// Secrets: GOOGLE_PLACES_KEY (same key as import-venues).
// Deploy with "Verify JWT" turned OFF — images load without a login header.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const REF = /^places\/[A-Za-z0-9_-]+\/photos\/[A-Za-z0-9_-]+$/;

// Google's photo links last a while; reuse them instead of paying again.
const cache = new Map<string, { uri: string; until: number }>();
const allowed = new Map<string, number>();

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const ref = url.searchParams.get("ref") ?? "";
  const width = Math.min(1600, Math.max(100, Number(url.searchParams.get("w") ?? "800") || 800));
  if (!REF.test(ref)) return new Response("Bad photo.", { status: 400 });

  const key = Deno.env.get("GOOGLE_PLACES_KEY");
  if (!key) return new Response("Photos aren't set up yet.", { status: 503 });

  const cacheKey = `${ref}@${width}`;
  const hit = cache.get(cacheKey);
  if (hit && hit.until > Date.now()) {
    return new Response(null, { status: 302, headers: { Location: hit.uri, "Cache-Control": "public, max-age=3600" } });
  }

  // Only photos of venues we imported.
  if ((allowed.get(ref) ?? 0) < Date.now()) {
    const { data } = await admin.from("venue_candidates").select("id").contains("photos", [{ name: ref }]).limit(1);
    if (!data || data.length === 0) return new Response("Unknown photo.", { status: 404 });
    allowed.set(ref, Date.now() + 60 * 60 * 1000);
  }

  const res = await fetch(
    `https://places.googleapis.com/v1/${ref}/media?maxWidthPx=${width}&skipHttpRedirect=true&key=${encodeURIComponent(key)}`,
  );
  if (!res.ok) return new Response("Photo unavailable.", { status: 502 });
  const body = await res.json();
  const uri = body.photoUri as string | undefined;
  if (!uri) return new Response("Photo unavailable.", { status: 502 });
  cache.set(cacheKey, { uri, until: Date.now() + 50 * 60 * 1000 });
  return new Response(null, { status: 302, headers: { Location: uri, "Cache-Control": "public, max-age=3600" } });
});
