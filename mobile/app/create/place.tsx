import React, { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { PlaceKind } from "@/data/types";
import { KindPicker } from "@/components/KindPicker";

const KINDS: { key: PlaceKind; label: string }[] = [
  { key: "frat", label: "Fraternity" },
  { key: "party", label: "Party" },
  { key: "bar", label: "Bar" },
  { key: "club", label: "Club" },
  { key: "event", label: "Event" },
  { key: "tailgate", label: "Tailgate" },
];

export default function CreatePlace() {
  const { tokens } = useTheme();
  const router = useRouter();
  const { addPlace, locationStatus } = useData();
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [kind, setKind] = useState<PlaceKind>("party");

  const canPost = name.trim().length > 0;

  const post = () => {
    if (!canPost) return;
    const place = addPlace(name.trim(), kind, address.trim() || "Address not given");
    router.replace(`/place/${place.id}` as any);
  };

  return (
    <ScrollView style={[styles.container, { backgroundColor: tokens.bg }]} contentContainerStyle={{ padding: 18 }}>
      <KindPicker active="place" />

      <Text style={{ color: tokens.mute, marginBottom: 6 }}>Name</Text>
      <TextInput
        value={name}
        onChangeText={setName}
        placeholder="Taverns Bar"
        placeholderTextColor={tokens.mute}
        maxLength={40}
        style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised }]}
      />

      <Text style={{ color: tokens.mute, marginTop: 16, marginBottom: 6 }}>Type</Text>
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
        {KINDS.map((k) => (
          <Pressable
            key={k.key}
            onPress={() => setKind(k.key)}
            style={[styles.kindChip, { backgroundColor: kind === k.key ? tokens.brand : tokens.raised }]}
          >
            <Text style={{ color: kind === k.key ? tokens.onOrange : tokens.ink, fontWeight: "700", fontSize: 13 }}>{k.label}</Text>
          </Pressable>
        ))}
      </View>

      <Text style={{ color: tokens.mute, marginTop: 16, marginBottom: 6 }}>Address</Text>
      <TextInput
        value={address}
        onChangeText={setAddress}
        placeholder="Street address"
        placeholderTextColor={tokens.mute}
        style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised }]}
      />
      <Text style={{ color: tokens.mute, fontSize: 12, marginTop: 6 }}>
        {locationStatus === "granted"
          ? "The pin drops at your current location — address lookup is a near-term follow-up (see HANDOFF.md)."
          : "Enable location first so this place can be placed on the map."}
      </Text>

      <Pressable onPress={post} style={[styles.postBtn, { backgroundColor: tokens.brand, opacity: canPost ? 1 : 0.5 }]}>
        <Text style={{ color: tokens.onOrange, fontWeight: "800" }}>Add place</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  input: { borderRadius: 12, paddingHorizontal: 14, paddingVertical: 12, fontSize: 15 },
  kindChip: { paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999 },
  postBtn: { marginTop: 22, paddingVertical: 14, borderRadius: 14, alignItems: "center" },
});
