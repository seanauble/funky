import { LatLng } from "./types";

/// Your area is the 25 miles around you (rule 1) — no area picker.
export const RANGE_MILES = 25;

/// Great-circle distance in miles between two points.
export function milesBetween(a: LatLng, b: LatLng): number {
  const R = 3958.8;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export function near(me: LatLng, pt: LatLng): boolean {
  return milesBetween(me, pt) <= RANGE_MILES;
}

export function formatMiles(mi: number): string {
  if (mi < 0.1) return "next to you";
  if (mi < 1) return `${(mi * 10).toFixed(0) === "10" ? "1" : (Math.round(mi * 10) / 10).toFixed(1)} mi`;
  return `${mi.toFixed(1)} mi`;
}
