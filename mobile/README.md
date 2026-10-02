# FUNKY — native app (Expo / React Native)

This is the native iOS/Android app HANDOFF.md's "What the owner wants next" #1 asks for, built with Expo + Expo Router + TypeScript so one codebase covers both platforms. It rebuilds the web prototype's (`../index.html`) screens and the thirteen product rules against **mock, on-device data** — there is no backend yet (see "What's mocked" below).

## Running it

```
npm install
npx expo install --fix   # aligns every package to whatever Expo SDK version npm install picked
npx expo start
```

Then press `i` for the iOS simulator, `a` for Android, or scan the QR code with Expo Go on your phone.

> This project's files were written without network access to npm, so dependency versions in `package.json` are my best estimate of a compatible, current set rather than ones actually installed and tested here. `npx expo install --fix` is what corrects any mismatch — run it right after `npm install` and before your first `npx expo start`.

## What's built

- **Navigation:** the five-tab bar from rule 12 — Home, Chat, a centre "+" that opens a modal (Story / Poll / Place, matching the prototype's one reused sheet), Places, Profile.
- **Theme:** colors ported exactly from `index.html`'s CSS custom properties (not re-guessed), plus the Light/Dark/Auto picker from rule 11.
- **Your area is 25 miles** (rule 1): real device location via `expo-location`, with the same "testing only" sample-town fallback the web prototype uses so it can be tried anywhere.
- **The 4 PM reset** (rule 2/3): `src/data/session.ts` ports `sessionKey()`/the reset check as real logic, not just a label — tonight-only fields are cleared and a "New day. New moves." screen (rule 2) shows once when that happens. What survives (handle, bio, points, following) is handled in `src/data/store.tsx`.
- **What's the move tonight?** (Home): builds itself from the busiest places, exactly like the prototype — not a stored poll.
- **Area chat + place chat**, polls with the orange→pink→purple bar gradient, adding a place or event, "I'm going" + reports (cover/police/shut-down) per place, Memories (list only for now — see below).

## What's mocked, not real yet

- **All data is local** (`src/data/mock.ts` + in-memory/AsyncStorage) — nothing is shared between people, same limitation the web prototype has outside Claude. This is the natural next step: HANDOFF.md's #2, a real backend (Supabase/Firebase) with the rules enforced server-side.
- **No camera.** Story posting is text-only for now; `expo-camera` + photo/video capture is the natural next addition once the backend exists to actually store media.
- **Places list, not a real map.** The Places tab is a sorted list with a placeholder where the heat map goes. `react-native-maps` (or Mapbox) with a satellite layer and address lookup is HANDOFF.md's #3.
- **No real Friends/DMs/Memories grouping.** Following is tracked, but mutual-follow friendship, private messages, and "a year ago today" Memory cards need real multi-night history and are left as the next layer once there's a backend to anchor them to.
- **No push notifications or moderation tools** — HANDOFF.md's #4 and #5, unchanged from the prototype's known limits.

## Project layout

```
app/                  Expo Router routes (file-based)
  (tabs)/              Home, Chat, Places, Profile + the hidden "create" tab slot
  create/              The Story/Poll/Place modal sheet
  place/[id].tsx        Place detail (I'm going, reports)
  memories.tsx
  _layout.tsx           Root stack, theme/data providers, the reset banner
src/
  theme/               Colors ported from index.html, light/dark/auto context
  data/                 Types mirroring HANDOFF's data model, session/reset logic, geo, mock store
  components/           Shared UI pieces
```
