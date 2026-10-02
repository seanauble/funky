import React from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { TOWNS } from "@/data/mock";
import { Card, Chip } from "./ui";

/// Shown wherever a screen needs a location and doesn't have one yet —
/// the native equivalent of the prototype's `gateHTML()`. Real location
/// is the primary path; the town list underneath is the same "testing
/// only" escape hatch the web prototype offers so FUNKY can be tried from
/// anywhere without real foot traffic nearby.
export function LocationGate() {
  const { tokens } = useTheme();
  const { requestLocation, locationStatus, useTestLocation } = useData();

  return (
    <ScrollView contentContainerStyle={{ flex: 1, padding: 20, justifyContent: "center" }} style={{ backgroundColor: tokens.bg }}>
      <Card style={{ alignItems: "center", paddingVertical: 28 }}>
        <Text style={{ fontSize: 40, marginBottom: 10 }}>📍</Text>
        <Text style={{ color: tokens.ink, fontWeight: "800", fontSize: 18, textAlign: "center" }}>Your area is the 25 miles around you</Text>
        <Text style={{ color: tokens.mute, textAlign: "center", marginTop: 6, marginBottom: 18 }}>
          FUNKY needs your location to show you what's happening near you tonight. It's never shown to other people — only a rough area.
        </Text>
        <Pressable
          onPress={requestLocation}
          style={{ backgroundColor: tokens.brand, paddingHorizontal: 20, paddingVertical: 12, borderRadius: 999 }}
        >
          <Text style={{ color: tokens.onOrange, fontWeight: "800" }}>
            {locationStatus === "requesting" ? "Requesting…" : "Enable location"}
          </Text>
        </Pressable>
        {locationStatus === "denied" && (
          <Text style={{ color: tokens.danger, marginTop: 10, textAlign: "center" }}>
            Location was denied. You can still try FUNKY with a sample town below.
          </Text>
        )}
      </Card>

      <Text style={{ color: tokens.mute, fontSize: 12, fontWeight: "700", marginTop: 24, marginBottom: 8, textAlign: "center" }}>
        TESTING ONLY — TRY A SAMPLE TOWN
      </Text>
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8, justifyContent: "center" }}>
        {TOWNS.map((town) => (
          <Chip key={town.label} label={town.label} onPress={() => useTestLocation({ lat: town.lat, lng: town.lng })} />
        ))}
      </View>
    </ScrollView>
  );
}
