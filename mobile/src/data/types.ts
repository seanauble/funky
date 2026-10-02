// Mirrors the data model documented in HANDOFF.md ("Data model (as stored
// inside Claude)") so swapping the mock store for a real backend later is a
// matter of changing where these records come from, not what shape they are.

export type LatLng = { lat: number; lng: number };

export type PlaceKind = "frat" | "party" | "bar" | "club" | "event" | "tailgate" | "area";

export type Place = {
  id: string;
  name: string;
  kind: PlaceKind;
  lat: number;
  lng: number;
  address: string;
  by: string; // userId who added it
  t: number; // created timestamp
  session: string; // night key — tonight-only, like everything but the survivors in rule 3
};

export type Poll = {
  id: string;
  q: string;
  options: string[];
  lat: number;
  lng: number;
  by: string;
  t: number;
  session: string;
};

export type Report = { cover: number; cops: boolean; shut: boolean };

export type ChatMessage = {
  id: string;
  t: number;
  room: string; // "main" (area chat) or a place id
  uid: string;
  text: string;
  anon: boolean;
};

export type Story = {
  id: string;
  t: number;
  uid: string;
  text?: string;
  tone?: string;
  place?: string; // "main" or a place id — which ring it belongs to
  img?: string;
  vid?: string;
  dur?: number;
  anon: boolean;
  session: string;
  views: string[]; // userIds who've seen it
  likes: string[]; // userIds who've liked it
};

export type DirectMessage = { id: string; t: number; to: string; from: string; text: string };

export type Person = {
  id: string;
  handle: string;
  bio: string;
  avatar?: string;
  since: number;
  points: number;
  following: string[];
  muted: string[];
  anon: boolean;
  demo?: boolean;

  // Tonight only — cleared by the 4 PM reset per rule 2.
  session: string;
  move: string | "in" | null; // a place id, "in" (staying in), or null (hasn't picked)
  votes: Record<string, number>; // pollId -> option index
  plans: Record<string, "going">; // placeId -> "going"
  reports: Record<string, Report>; // placeId -> report
  seen: string[]; // story ids seen
  likes: string[]; // story ids liked
};

export type Memory = {
  id: string; // mirrors the originating story id
  t: number;
  text?: string;
  img?: string;
  place?: string;
};
