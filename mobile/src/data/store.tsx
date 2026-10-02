import React, { createContext, useContext, useEffect, useMemo, useState, useCallback } from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";
import * as Location from "expo-location";
import { ChatMessage, LatLng, Person, Place, PlaceKind, Poll, Report, Story } from "./types";
import { sessionKey, untilReset as untilResetStr } from "./session";
import {
  DEFAULT_LOCATION,
  SAMPLE_MESSAGES,
  SAMPLE_PEOPLE,
  SAMPLE_PLACES,
  SAMPLE_POLLS,
  SAMPLE_STORIES,
  freshMe,
} from "./mock";
import { milesBetween, near } from "./geo";

const STORAGE_KEY = "funky.store.v1";

type Persisted = {
  session: string;
  me: Person;
  places: Place[];
  polls: Poll[];
  messages: ChatMessage[];
  stories: Story[];
};

type LocationStatus = "unknown" | "requesting" | "granted" | "denied";

export type RankedPlace = Place & {
  distance: number;
  going: number;
  heat: number; // 0-3, matches HEAT labels
  cover?: Report;
};

type DataContextValue = {
  me: Person;
  people: Record<string, Person>;
  location: LatLng | null;
  locationStatus: LocationStatus;
  requestLocation: () => Promise<void>;
  useTestLocation: (loc: LatLng) => void;
  rankedPlaces: RankedPlace[];
  polls: Poll[];
  roomsForChat: { id: string; name: string; heat: number }[];
  messagesFor: (room: string) => ChatMessage[];
  storiesFor: (ring: string) => Story[];
  myStories: Story[];
  justReset: boolean;
  dismissResetBanner: () => void;
  untilReset: () => string;

  setHandle: (handle: string) => void;
  setBio: (bio: string) => void;
  setMove: (placeIdOrIn: string) => void;
  votePoll: (pollId: string, optionIndex: number) => void;
  addPlace: (name: string, kind: PlaceKind, address: string) => Place;
  addPoll: (q: string, options: string[]) => Poll;
  sendMessage: (room: string, text: string, anon: boolean) => void;
  addStory: (input: { text?: string; place: string; anon: boolean }) => void;
  likeStory: (id: string) => void;
  reportPlace: (placeId: string, patch: Partial<Report>) => void;
};

const DataCtx = createContext<DataContextValue | null>(null);

export function DataProvider({ children }: { children: React.ReactNode }) {
  const [loaded, setLoaded] = useState(false);
  const [justReset, setJustReset] = useState(false);

  const [me, setMe] = useState<Person>(freshMe());
  const [people] = useState<Record<string, Person>>(() => {
    const map: Record<string, Person> = {};
    for (const p of SAMPLE_PEOPLE) map[p.id] = p;
    return map;
  });

  const [places, setPlaces] = useState<Place[]>(SAMPLE_PLACES);
  const [polls, setPolls] = useState<Poll[]>(SAMPLE_POLLS);
  const [messages, setMessages] = useState<ChatMessage[]>(SAMPLE_MESSAGES);
  const [stories, setStories] = useState<Story[]>(SAMPLE_STORIES);

  const [location, setLocation] = useState<LatLng | null>(null);
  const [locationStatus, setLocationStatus] = useState<LocationStatus>("unknown");

  // Load persisted state, applying the 4 PM reset (rule 2) if the stored
  // session is stale: tonight-only fields on `me` and anything the person
  // added themselves get cleared, while handle/bio/points/following survive
  // (rule 3). Demo seed content is always fresh, so it isn't persisted.
  useEffect(() => {
    (async () => {
      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        const currentSession = sessionKey();
        if (raw) {
          const parsed: Persisted = JSON.parse(raw);
          if (parsed.session === currentSession) {
            setMe(parsed.me);
            setPlaces((prev) => dedupeById([...prev, ...parsed.places]));
            setPolls((prev) => dedupeById([...prev, ...parsed.polls]));
            setMessages((prev) => dedupeById([...prev, ...parsed.messages]));
            setStories((prev) => dedupeById([...prev, ...parsed.stories]));
          } else {
            // Stale night — carry over only what survives the reset.
            setMe((prev) => ({
              ...freshMe(),
              id: parsed.me.id,
              handle: parsed.me.handle,
              bio: parsed.me.bio,
              avatar: parsed.me.avatar,
              since: parsed.me.since,
              points: parsed.me.points,
              following: parsed.me.following,
              muted: parsed.me.muted,
            }));
            setJustReset(true);
          }
        }
      } catch {
        // Corrupt or missing storage — just start fresh, same as a new install.
      } finally {
        setLoaded(true);
      }
    })();
  }, []);

  // Persist on every change, once the initial load has settled.
  useEffect(() => {
    if (!loaded) return;
    const ownPlaces = places.filter((p) => p.by === "me");
    const ownPolls = polls.filter((p) => p.by === "me");
    const ownMessages = messages.filter((m) => m.uid === "me");
    const ownStories = stories.filter((s) => s.uid === "me");
    const payload: Persisted = {
      session: sessionKey(),
      me,
      places: ownPlaces,
      polls: ownPolls,
      messages: ownMessages,
      stories: ownStories,
    };
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(payload)).catch(() => {
      // Non-fatal — worst case this session's additions don't survive a reload.
    });
  }, [loaded, me, places, polls, messages, stories]);

  const requestLocation = useCallback(async () => {
    setLocationStatus("requesting");
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== "granted") {
        setLocationStatus("denied");
        return;
      }
      const pos = await Location.getCurrentPositionAsync({});
      setLocation({ lat: pos.coords.latitude, lng: pos.coords.longitude });
      setLocationStatus("granted");
    } catch {
      setLocationStatus("denied");
    }
  }, []);

  // A manual override for trying the app away from real sample places —
  // the native equivalent of the prototype's "testing only" town picker.
  const useTestLocation = useCallback((loc: LatLng) => {
    setLocation(loc);
    setLocationStatus("granted");
  }, []);

  const rankedPlaces: RankedPlace[] = useMemo(() => {
    const here = location ?? DEFAULT_LOCATION;
    const allPeople = { ...people, me };
    return places
      .filter((p) => near(here, { lat: p.lat, lng: p.lng }))
      .map((p) => {
        const going = Object.values(allPeople).filter((person) => person.move === p.id).length;
        const roomMsgCount = messages.filter((m) => m.room === p.id).length;
        const storyCount = stories.filter((s) => s.place === p.id).length;
        const score = going * 3 + roomMsgCount + storyCount * 2;
        const heat = score >= 12 ? 3 : score >= 5 ? 2 : score >= 1 ? 1 : 0;
        const cover = me.reports[p.id];
        return {
          ...p,
          distance: milesBetween(here, { lat: p.lat, lng: p.lng }),
          going,
          heat,
          cover,
        };
      })
      .sort((a, b) => b.heat - a.heat || b.going - a.going || a.distance - b.distance);
  }, [places, location, people, me, messages, stories]);

  const roomsForChat = useMemo(() => {
    const here = location ?? DEFAULT_LOCATION;
    return [{ id: "main", name: "Area chat", heat: 0 }].concat(
      rankedPlaces.map((p) => ({ id: p.id, name: p.name, heat: p.heat }))
    );
  }, [rankedPlaces, location]);

  const messagesFor = useCallback((room: string) => messages.filter((m) => m.room === room).sort((a, b) => a.t - b.t), [messages]);
  const storiesFor = useCallback((ring: string) => stories.filter((s) => s.place === ring), [stories]);
  const myStories = useMemo(() => stories.filter((s) => s.uid === "me").sort((a, b) => b.t - a.t), [stories]);

  const setHandle = useCallback((handle: string) => setMe((m) => ({ ...m, handle })), []);
  const setBio = useCallback((bio: string) => setMe((m) => ({ ...m, bio })), []);
  const setMove = useCallback((placeIdOrIn: string) => setMe((m) => ({ ...m, move: placeIdOrIn })), []);

  const votePoll = useCallback((pollId: string, optionIndex: number) => {
    setMe((m) => ({ ...m, votes: { ...m.votes, [pollId]: optionIndex } }));
  }, []);

  const addPlace = useCallback(
    (name: string, kind: PlaceKind, address: string): Place => {
      const here = location ?? DEFAULT_LOCATION;
      const place: Place = {
        id: `place_${Date.now()}`,
        name,
        kind,
        lat: here.lat,
        lng: here.lng,
        address,
        by: "me",
        t: Date.now(),
        session: sessionKey(),
      };
      setPlaces((prev) => [...prev, place]);
      return place;
    },
    [location]
  );

  const addPoll = useCallback(
    (q: string, options: string[]): Poll => {
      const here = location ?? DEFAULT_LOCATION;
      const poll: Poll = {
        id: `poll_${Date.now()}`,
        q,
        options,
        lat: here.lat,
        lng: here.lng,
        by: "me",
        t: Date.now(),
        session: sessionKey(),
      };
      setPolls((prev) => [...prev, poll]);
      return poll;
    },
    [location]
  );

  const sendMessage = useCallback((room: string, text: string, anon: boolean) => {
    const message: ChatMessage = { id: `msg_${Date.now()}`, t: Date.now(), room, uid: "me", text, anon };
    setMessages((prev) => [...prev, message]);
  }, []);

  const addStory = useCallback(({ text, place, anon }: { text?: string; place: string; anon: boolean }) => {
    const story: Story = {
      id: `story_${Date.now()}`,
      t: Date.now(),
      uid: "me",
      text,
      place,
      anon,
      session: sessionKey(),
      views: [],
      likes: [],
    };
    setStories((prev) => [...prev, story]);
  }, []);

  const likeStory = useCallback((id: string) => {
    setStories((prev) => prev.map((s) => (s.id === id && !s.likes.includes("me") ? { ...s, likes: [...s.likes, "me"] } : s)));
  }, []);

  const reportPlace = useCallback((placeId: string, patch: Partial<Report>) => {
    setMe((m) => ({
      ...m,
      reports: {
        ...m.reports,
        [placeId]: { cover: 0, cops: false, shut: false, ...m.reports[placeId], ...patch },
      },
    }));
  }, []);

  const dismissResetBanner = useCallback(() => setJustReset(false), []);
  const untilReset = useCallback(() => untilResetStr(), []);

  const value: DataContextValue = {
    me,
    people,
    location,
    locationStatus,
    requestLocation,
    useTestLocation,
    rankedPlaces,
    polls: polls.filter((p) => near(location ?? DEFAULT_LOCATION, { lat: p.lat, lng: p.lng })),
    roomsForChat,
    messagesFor,
    storiesFor,
    myStories,
    justReset,
    dismissResetBanner,
    untilReset,
    setHandle,
    setBio,
    setMove,
    votePoll,
    addPlace,
    addPoll,
    sendMessage,
    addStory,
    likeStory,
    reportPlace,
  };

  if (!loaded) return null;

  return <DataCtx.Provider value={value}>{children}</DataCtx.Provider>;
}

export function useData() {
  const ctx = useContext(DataCtx);
  if (!ctx) throw new Error("useData must be used inside a DataProvider");
  return ctx;
}

function dedupeById<T extends { id: string }>(items: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const item of items) {
    if (seen.has(item.id)) continue;
    seen.add(item.id);
    out.push(item);
  }
  return out;
}
