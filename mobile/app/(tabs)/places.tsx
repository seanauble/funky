import React from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { formatMiles } from "@/data/geo";
import { EmptyNote, FootNote } from "@/components/ui";
import { LocationGate } from "@/components/LocationGate";

const HEAT_LABEL = ["Quiet so far", "Some activity", "Active", "Very active"];
const KIND_LABEL: Record<string, string> = {
  frat: "Fraternity",
  party: "Party",
  bar: "Bar",
  club: "Club",
  event: "Event",
  tailgate: "Tailgate",
  area: "Area",
};

export default function PlacesScreen() {
  const { tokens } = useTheme();
  const router = useRouter();
  const { location, rankedPlaces } = useData();

  if (!location) return <LocationGate />;

  return (
    <View style={{ flex: 1, backgroundColor: tokens.bg }}>
      {/* A real satellite map with a heat layer is next (see HANDOFF.md) —
          this radial placeholder stands in for it so the screen is useful
          today instead of blank. */}
      <View style={[styles.mapPlaceholder, { backgroundColor: tokens.map, borderColor: tokens.mapLine }]}>
        <View style={[styles.youDot, { backgroundColor: tokens.you }]} />
        <Text style={{ color: tokens.mute, marginTop: 10 }}>Map view coming next — list is live below</Text>
      </View>

      <ScrollView contentContainerStyle={styles.content}>
        {rankedPlaces.length === 0 ? (
          <EmptyNote text="Nothing is listed within 25 miles yet. Be the first to add one." />
        ) : (
          rankedPlaces.map((p) => (
            <Pressable key={p.id} onPress={() => router.push(`/place/${p.id}`)} style={[styles.row, { borderColor: tokens.line }]}>
              <View style={[styles.cover, { backgroundColor: tokens.raised }]}>
                <Text style={{ fontWeight: "800", color: tokens.mute }}>{p.name.slice(0, 1)}</Text>
              </View>
              <View style={{ flex: 1 }}>
                <Text style={{ color: tokens.ink, fontWeight: "700" }} numberOfLines={1}>
                  {p.name}
                </Text>
                <Text style={{ color: tokens.mute, fontSize: 12.5, marginTop: 2 }}>
                  {KIND_LABEL[p.kind]} · 🔥 {p.going} going
                  {p.heat > 0 ? ` · ${HEAT_LABEL[p.heat]}` : ""}
                  {p.cover?.shut ? " · Shut down" : ""}
                  {p.cover?.cops ? " · 🚨 Police" : ""}
                  {p.cover && p.cover.cover > 0 ? ` · $${p.cover.cover} cover` : ""}
                </Text>
              </View>
              <Text style={{ color: tokens.mute, fontSize: 12.5 }}>{formatMiles(p.distance)}</Text>
            </Pressable>
          ))
        )}
        <FootNote text="Places are tonight-only, like everything else — wiped at 4 PM." />
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  mapPlaceholder: { height: 180, borderBottomWidth: 1, alignItems: "center", justifyContent: "center" },
  youDot: { width: 14, height: 14, borderRadius: 7, borderWidth: 2, borderColor: "#fff" },
  content: { padding: 16, paddingBottom: 40 },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 12, borderBottomWidth: 1 },
  cover: { width: 44, height: 44, borderRadius: 10, alignItems: "center", justifyContent: "center" },
});
