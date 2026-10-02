// Seed data for the mock store — lifted directly from the web prototype's
// own `FALLBACK` block (the "three sample places near Glassboro, NJ" mode
// HANDOFF.md describes) so the native app starts from the exact same
// sample night instead of inventing new placeholder content.

import { ChatMessage, LatLng, Person, Place, Poll, Story } from "./types";
import { sessionKey } from "./session";

export const DEFAULT_LOCATION: LatLng = { lat: 39.7052, lng: -75.114 }; // Glassboro, NJ

export const TOWNS: { label: string; lat: number; lng: number }[] = [
  { label: "Glassboro, NJ", lat: 39.7052, lng: -75.114 },
  { label: "Philadelphia, PA", lat: 39.9526, lng: -75.1652 },
  { label: "Atlantic City, NJ", lat: 39.3625, lng: -74.425 },
  { label: "Ocean City, NJ", lat: 39.2776, lng: -74.5746 },
  { label: "Hoboken, NJ", lat: 40.744, lng: -74.0324 },
];

const session = sessionKey();

export const SAMPLE_PLACES: Place[] = [
  { id: "sigchi", name: "Sigma Chi", kind: "frat", lat: 39.7075, lng: -75.1235, address: "214 Mullica Hill Rd", by: "demo", t: Date.now(), session },
  { id: "pike", name: "Pike", kind: "frat", lat: 39.7135, lng: -75.115, address: "301 Whitney Ave", by: "demo", t: Date.now(), session },
  { id: "downtown", name: "Downtown", kind: "area", lat: 39.7045, lng: -75.1125, address: "High St & Delsea Dr", by: "demo", t: Date.now(), session },
  { id: "hq", name: "HQ Nightclub", kind: "club", lat: 39.362, lng: -74.413, address: "Atlantic City, NJ", by: "demo", t: Date.now(), session },
  { id: "point", name: "The Point", kind: "bar", lat: 39.308, lng: -74.595, address: "Ocean City, NJ", by: "demo", t: Date.now(), session },
];

export const SAMPLE_POLLS: Poll[] = [
  { id: "rowan-out", q: "Going out tonight?", options: ["Obviously", "Maybe", "Staying in"], lat: 39.7102, lng: -75.1196, by: "demo", t: Date.now(), session },
  { id: "ac-best", q: "Best bar tonight?", options: ["The Point", "HQ Nightclub", "Somewhere else"], lat: 39.3643, lng: -74.4229, by: "demo", t: Date.now(), session },
];

export const SAMPLE_PEOPLE: Person[] = [
  mkDemo("p1", "wildcard92", "here for the pregame", "sigchi"),
  mkDemo("p2", "shortkingjames", "rowan '27", "downtown"),
  mkDemo("p3", "beachbum", "AC this weekend", "point"),
];

function mkDemo(id: string, handle: string, bio: string, move: string): Person {
  return {
    id,
    handle,
    bio,
    since: 2026,
    points: Math.floor(20 + Math.random() * 180),
    following: [],
    muted: [],
    anon: false,
    demo: true,
    session,
    move,
    votes: {},
    plans: { [move]: "going" },
    reports: {},
    seen: [],
    likes: [],
  };
}

export const SAMPLE_MESSAGES: ChatMessage[] = [
  { id: "m1", t: Date.now() - 1000 * 60 * 42, room: "main", uid: "p1", text: "who's actually going out tonight", anon: false },
  { id: "m2", t: Date.now() - 1000 * 60 * 35, room: "main", uid: "p2", text: "sig chi is giving pregame energy rn", anon: false },
  { id: "m3", t: Date.now() - 1000 * 60 * 12, room: "sigchi", uid: "p1", text: "line is already out the door 💀", anon: false },
];

export const SAMPLE_STORIES: Story[] = [
  { id: "s1", t: Date.now() - 1000 * 60 * 50, uid: "p1", text: "pregame loading", place: "sigchi", anon: false, session, views: [], likes: ["p2"] },
  { id: "s2", t: Date.now() - 1000 * 60 * 20, uid: "p3", text: "boardwalk before the bars", place: "point", anon: false, session, views: [], likes: [] },
];

export function freshMe(): Person {
  return {
    id: "me",
    handle: "you",
    bio: "",
    since: new Date().getFullYear(),
    points: 0,
    following: [],
    muted: [],
    anon: false,
    session,
    move: null,
    votes: {},
    plans: {},
    reports: {},
    seen: [],
    likes: [],
  };
}
