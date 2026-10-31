// FUNKY — import-venues Edge Function (OpenStreetMap, free, no API key).
//
// Finds every bar, pub and nightclub within 50 miles of the admin's current
// location (sent by the app; Egg Harbor, NJ if location is off) from
// OpenStreetMap and adds them to venue_candidates for the admin to approve,
// deny, or fix up (and add a photo to) in the app: Admin panel → New venues.
// Venues already imported, or already on the map under the same name, are
// skipped — so it's safe to run again later to catch new spots.
//
// Map data © OpenStreetMap contributors (ODbL).
//
// No secrets needed. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// provided automatically. Deploy with "Verify JWT" turned OFF — this
// function checks itself that the caller is a FUNKY admin.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const OWNER_EMAIL = "seanauble@icloud.com";

// Egg Harbor Township, NJ — used when the app doesn't send a location.
const DEFAULT_CENTER = { lat: 39.3926, lng: -74.6202 };
const RADIUS_MILES = 50;

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function milesBetween(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const r = 3958.8;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

type OsmElement = {
  type: string;
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  tags?: Record<string, string>;
};

async function overpass(query: string): Promise<OsmElement[]> {
  let lastError = "";
  for (const url of OVERPASS) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "FUNKY-app/1.0 (venue import)" },
        body: "data=" + encodeURIComponent(query),
      });
      if (!res.ok) {
        lastError = `${url} said ${res.status}`;
        continue;
      }
      const data = await res.json();
      return (data.elements ?? []) as OsmElement[];
    } catch (e) {
      lastError = String(e instanceof Error ? e.message : e);
    }
  }
  throw new Error(`OpenStreetMap is busy right now (${lastError}). Try again in a minute.`);
}

function addressOf(t: Record<string, string>): string {
  if (t["addr:full"]) return t["addr:full"];
  const street = [t["addr:housenumber"], t["addr:street"]].filter(Boolean).join(" ");
  const city = t["addr:city"] ?? t["addr:town"] ?? t["addr:village"] ?? "";
  const state = t["addr:state"] ?? "";
  return [street, city, [state, t["addr:postcode"]].filter(Boolean).join(" ")].filter((s) => s && s.trim()).join(", ");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  // Admins only.
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!bearer) return json({ error: "Log in first." }, 401);
  const { data: auth, error: authError } = await admin.auth.getUser(bearer);
  if (authError || !auth?.user) return json({ error: "Log in again, then retry." }, 401);
  const email = (auth.user.email ?? "").toLowerCase();
  if (email !== OWNER_EMAIL) {
    const { data: profile } = await admin.from("profiles").select("is_admin").eq("id", auth.user.id).maybeSingle();
    if (!profile?.is_admin) return json({ error: "Admins only." }, 403);
  }

  // Search around wherever the admin is right now.
  let CENTER = DEFAULT_CENTER;
  try {
    const body = await req.json();
    const lat = Number(body?.lat);
    const lng = Number(body?.lng);
    if (Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180) {
      CENTER = { lat, lng };
    }
  } catch (_) {
    // No body — use the default.
  }

  const meters = Math.round(RADIUS_MILES * 1609.344);
  const query = `[out:json][timeout:90];
(
  nwr["amenity"~"^(bar|pub|nightclub|biergarten)$"](around:${meters},${CENTER.lat},${CENTER.lng});
);
out center tags;`;

  let elements: OsmElement[];
  try {
    elements = await overpass(query);
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 502);
  }

  const { data: existing } = await admin.from("venue_candidates").select("google_place_id");
  const known = new Set((existing ?? []).map((r: { google_place_id: string }) => r.google_place_id));
  const { data: places } = await admin.from("places").select("name, lat, lng");
  const onMap = (places ?? []) as { name: string; lat: number; lng: number }[];

  const rows = [];
  const seen = new Set<string>();
  let unnamed = 0;
  let duplicate = 0;
  let already = 0;
  for (const el of elements) {
    const t = el.tags ?? {};
    const name = (t.name ?? "").trim();
    const lat = el.lat ?? el.center?.lat;
    const lng = el.lon ?? el.center?.lon;
    if (!name || lat == null || lng == null) {
      unnamed++;
      continue;
    }
    if (t["disused:amenity"] || t["opening_hours"] === "closed") continue;
    const sourceId = `osm:${el.type}/${el.id}`;
    if (known.has(sourceId)) {
      already++;
      continue;
    }
    const lower = name.toLowerCase();
    // The same place mapped twice (a pin and a building outline).
    const dupKey = `${lower}@${lat.toFixed(3)},${lng.toFixed(3)}`;
    if (seen.has(dupKey)) continue;
    seen.add(dupKey);
    if (onMap.some((m) => m.name.toLowerCase() === lower && milesBetween(m.lat, m.lng, lat, lng) < 0.2)) {
      duplicate++;
      continue;
    }
    const miles = milesBetween(CENTER.lat, CENTER.lng, lat, lng);
    if (miles > RADIUS_MILES) continue;
    rows.push({
      google_place_id: sourceId,
      name: name.slice(0, 60),
      kind: t.amenity === "nightclub" ? "club" : "bar",
      address: addressOf(t).slice(0, 120),
      lat,
      lng,
      distance_miles: Math.round(miles * 10) / 10,
      photos: [],
    });
  }

  for (let i = 0; i < rows.length; i += 200) {
    const { error } = await admin.from("venue_candidates").upsert(rows.slice(i, i + 200), { onConflict: "google_place_id", ignoreDuplicates: true });
    if (error) return json({ error: `Saving failed: ${error.message}` }, 500);
  }

  return json({ found: elements.length, added: rows.length, already, duplicate, unnamed, center: CENTER });
});
