import React, { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { KindPicker } from "@/components/KindPicker";

export default function CreateStory() {
  const { tokens } = useTheme();
  const router = useRouter();
  const { rankedPlaces, addStory } = useData();
  const [text, setText] = useState("");
  const [anon, setAnon] = useState(false);
  const [place, setPlace] = useState("main");

  const post = () => {
    if (!text.trim()) return;
    addStory({ text: text.trim(), place, anon });
    router.back();
  };

  return (
    <View style={[styles.container, { backgroundColor: tokens.bg }]}>
      <KindPicker active="story" />

      <Text style={{ color: tokens.mute, fontSize: 13, marginBottom: 8 }}>
        Camera Stories are coming next — text Stories work today and post the same way (full screen, auto-advance, likes).
      </Text>

      <TextInput
        value={text}
        onChangeText={setText}
        placeholder="What's happening?"
        placeholderTextColor={tokens.mute}
        multiline
        style={[styles.textArea, { color: tokens.ink, backgroundColor: tokens.raised }]}
        maxLength={200}
      />

      <Text style={{ color: tokens.mute, fontSize: 13, marginTop: 14, marginBottom: 8 }}>Post to</Text>
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
        <PlaceOption label="Area" active={place === "main"} onPress={() => setPlace("main")} />
        {rankedPlaces.slice(0, 6).map((p) => (
          <PlaceOption key={p.id} label={p.name} active={place === p.id} onPress={() => setPlace(p.id)} />
        ))}
      </View>

      <Pressable onPress={() => setAnon((a) => !a)} style={[styles.anonRow]}>
        <View style={[styles.checkbox, { borderColor: tokens.line, backgroundColor: anon ? tokens.brand : "transparent" }]} />
        <Text style={{ color: tokens.ink }}>Post anonymously</Text>
      </Pressable>

      <Pressable onPress={post} style={[styles.postBtn, { backgroundColor: tokens.brand, opacity: text.trim() ? 1 : 0.5 }]}>
        <Text style={{ color: tokens.onOrange, fontWeight: "800" }}>Post Story</Text>
      </Pressable>
    </View>
  );
}

function PlaceOption({ label, active, onPress }: { label: string; active: boolean; onPress: () => void }) {
  const { tokens } = useTheme();
  return (
    <Pressable onPress={onPress} style={[styles.placeChip, { backgroundColor: active ? tokens.brand : tokens.raised }]}>
      <Text style={{ color: active ? tokens.onOrange : tokens.ink, fontWeight: "700", fontSize: 13 }} numberOfLines={1}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 18 },
  textArea: { minHeight: 100, borderRadius: 14, padding: 14, fontSize: 16, textAlignVertical: "top" },
  placeChip: { paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999 },
  anonRow: { flexDirection: "row", alignItems: "center", gap: 10, marginTop: 20 },
  checkbox: { width: 20, height: 20, borderRadius: 5, borderWidth: 1.5 },
  postBtn: { marginTop: 22, paddingVertical: 14, borderRadius: 14, alignItems: "center" },
});
