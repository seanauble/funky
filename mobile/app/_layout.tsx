import React from "react";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { ThemeProvider, useTheme } from "@/theme/ThemeContext";
import { DataProvider } from "@/data/store";
import { ResetBanner } from "@/components/ResetBanner";

function RootStack() {
  const { tokens, isDark } = useTheme();
  return (
    <>
      <StatusBar style={isDark ? "light" : "dark"} />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: tokens.bg },
          headerTintColor: tokens.ink,
          headerShadowVisible: false,
          contentStyle: { backgroundColor: tokens.bg },
        }}
      >
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="create/index" options={{ presentation: "modal", title: "Add to your story" }} />
        <Stack.Screen name="create/poll" options={{ presentation: "modal", title: "Ask a poll" }} />
        <Stack.Screen name="create/place" options={{ presentation: "modal", title: "Add a place or event" }} />
        <Stack.Screen name="place/[id]" options={{ title: "Place" }} />
        <Stack.Screen name="memories" options={{ title: "Memories" }} />
      </Stack>
      <ResetBanner />
    </>
  );
}

export default function RootLayout() {
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <ThemeProvider>
        <DataProvider>
          <RootStack />
        </DataProvider>
      </ThemeProvider>
    </GestureHandlerRootView>
  );
}
