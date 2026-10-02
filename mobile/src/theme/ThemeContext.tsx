import React, { createContext, useContext, useEffect, useMemo, useState } from "react";
import { useColorScheme } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { dark, light, ThemeTokens } from "./colors";

export type ThemePreference = "light" | "dark" | "auto";

const STORAGE_KEY = "funky.themePreference";

type ThemeContextValue = {
  tokens: ThemeTokens;
  isDark: boolean;
  preference: ThemePreference;
  setPreference: (p: ThemePreference) => void;
};

const ThemeCtx = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const systemScheme = useColorScheme();
  const [preference, setPreferenceState] = useState<ThemePreference>("auto");
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    AsyncStorage.getItem(STORAGE_KEY).then((stored) => {
      if (stored === "light" || stored === "dark" || stored === "auto") {
        setPreferenceState(stored);
      }
      setLoaded(true);
    });
  }, []);

  const setPreference = (p: ThemePreference) => {
    setPreferenceState(p);
    AsyncStorage.setItem(STORAGE_KEY, p).catch(() => {
      // Non-fatal — the in-memory preference still applies for this session.
    });
  };

  const isDark = preference === "auto" ? systemScheme !== "light" : preference === "dark";
  const tokens = isDark ? dark : light;

  const value = useMemo(
    () => ({ tokens, isDark, preference, setPreference }),
    [tokens, isDark, preference]
  );

  // Avoid a one-frame flash of the wrong theme while AsyncStorage resolves.
  if (!loaded) return null;

  return <ThemeCtx.Provider value={value}>{children}</ThemeCtx.Provider>;
}

export function useTheme() {
  const ctx = useContext(ThemeCtx);
  if (!ctx) throw new Error("useTheme must be used inside a ThemeProvider");
  return ctx;
}
