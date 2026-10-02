import React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";

/// The prototype reuses one sheet for Story, Poll, and Place (rule 6 /
/// HANDOFF "Sheets"). The three `create/*` modal routes stand in for that
/// single reused sheet, and this picker row — shared by all three — is
/// what makes switching between them feel like one sheet instead of three
/// unrelated screens.
export function KindPicker({ active }: { active: "story" | "poll" | "place" }) {
  const { tokens } = useTheme();
  const router = useRouter();
  const kinds: { key: "story" | "poll" | "place"; label: string; href: string }[] = [
    { key: "story", label: "Story", href: "/create" },
    { key: "poll", label: "Poll", href: "/create/poll" },
    { key: "place", label: "Place", href: "/create/place" },
  ];
  return (
    <View style={[styles.kindRow, { backgroundColor: tokens.raised }]}>
      {kinds.map((k) => (
        <Pressable
          key={k.key}
          onPress={() => k.key !== active && router.replace(k.href as any)}
          style={[styles.kindBtn, k.key === active && { borderColor: tokens.ink, borderWidth: 1.5 }]}
        >
          <Text style={{ color: tokens.ink, fontWeight: "700" }}>{k.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  kindRow: { flexDirection: "row", borderRadius: 10, padding: 3, marginBottom: 16, gap: 3 },
  kindBtn: { flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: "center" },
});
