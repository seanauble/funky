import React, { useState } from "react";
import { Alert, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { formatMiles } from "@/data/geo";
import { Card } from "@/components/ui";

export default function PlaceDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { tokens } = useTheme();
  const router = useRouter();
  const { rankedPlaces, me, setMove, reportPlace } = useData();
  const [coverInput, setCoverInput] = useState("");

  const place = rankedPlaces.find((p) => p.id === id);
  if (!place) {
    return (
      <View style={[styles.container, { backgroundColor: tokens.bg }]}>
        <Text style={{ color: tokens.ink }}>This place isn't around anymore tonight.</Text>
      </View>
    );
  }

  const going = me.move === place.id;

  return (
    <ScrollView style={{ flex: 1, backgroundColor: tokens.bg }} contentContainerStyle={styles.container}>
      <View style={[styles.hero, { backgroundColor: tokens.raised }]}>
        <Text style={{ fontSize: 40, fontWeight: "800", color: tokens.mute }}>{place.name.slice(0, 1)}</Text>
      </View>
      <Text style={{ color: tokens.ink, fontSize: 22, fontWeight: "800", marginTop: 14 }}>{place.name}</Text>
      <Text style={{ color: tokens.mute, marginTop: 4 }}>
        {place.address} · {formatMiles(place.distance)}
      </Text>

      <Pressable
        onPress={() => setMove(going ? "in" : place.id)}
        style={[styles.goingBtn, { backgroundColor: going ? tokens.raised : tokens.brand }]}
      >
        <Text style={{ color: going ? tokens.ink : tokens.onOrange, fontWeight: "800" }}>
          {going ? "You're going ✓" : "I'm going"}
        </Text>
      </Pressable>
      <Text style={{ color: tokens.mute, marginTop: 8 }}>🔥 {place.going} going tonight</Text>

      <Card style={{ marginTop: 20 }}>
        <Text style={{ color: tokens.ink, fontWeight: "800", marginBottom: 10 }}>Reports tonight</Text>
        <Text style={{ color: tokens.mute, fontSize: 12.5, marginBottom: 12 }}>Shown as totals — never who reported.</Text>

        <View style={{ flexDirection: "row", gap: 10, marginBottom: 12 }}>
          <TextInput
            value={coverInput}
            onChangeText={setCoverInput}
            placeholder="Cover charge ($)"
            placeholderTextColor={tokens.mute}
            keyboardType="number-pad"
            style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised }]}
          />
          <Pressable
            onPress={() => {
              const amt = parseInt(coverInput, 10);
              if (!Number.isFinite(amt) || amt < 0) {
                Alert.alert("Enter a cover amount first");
                return;
              }
              reportPlace(place.id, { cover: amt });
              setCoverInput("");
            }}
            style={[styles.reportBtn, { backgroundColor: tokens.raised }]}
          >
            <Text style={{ color: tokens.ink, fontWeight: "700" }}>Report</Text>
          </Pressable>
        </View>

        <View style={{ flexDirection: "row", gap: 10 }}>
          <Pressable onPress={() => reportPlace(place.id, { cops: !place.cover?.cops })} style={[styles.toggle, { backgroundColor: place.cover?.cops ? tokens.danger : tokens.raised }]}>
            <Text style={{ color: place.cover?.cops ? "#fff" : tokens.ink, fontWeight: "700" }}>🚨 Police</Text>
          </Pressable>
          <Pressable onPress={() => reportPlace(place.id, { shut: !place.cover?.shut })} style={[styles.toggle, { backgroundColor: place.cover?.shut ? tokens.danger : tokens.raised }]}>
            <Text style={{ color: place.cover?.shut ? "#fff" : tokens.ink, fontWeight: "700" }}>Shut down</Text>
          </Pressable>
        </View>
      </Card>

      <Pressable onPress={() => router.push(`/chat`)} style={[styles.chatLink]}>
        <Text style={{ color: tokens.orange, fontWeight: "700" }}>Open this place's chat →</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { padding: 20, paddingBottom: 40 },
  hero: { height: 160, borderRadius: 18, alignItems: "center", justifyContent: "center" },
  goingBtn: { marginTop: 18, paddingVertical: 14, borderRadius: 14, alignItems: "center" },
  input: { flex: 1, borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10 },
  reportBtn: { paddingHorizontal: 16, borderRadius: 10, alignItems: "center", justifyContent: "center" },
  toggle: { flex: 1, paddingVertical: 10, borderRadius: 10, alignItems: "center" },
  chatLink: { marginTop: 20, alignItems: "center" },
});
