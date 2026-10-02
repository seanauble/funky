import React from "react";
import { Pressable, ScrollView, StyleSheet, Switch, Text, TextInput, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme, ThemePreference } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { Avatar, Card, SectionHeader } from "@/components/ui";

export default function ProfileScreen() {
  const { tokens, preference, setPreference } = useTheme();
  const router = useRouter();
  const { me, setHandle, setBio } = useData();

  const friends = 0; // mutual follows — real once DMs/friends are wired to a backend
  const following = me.following.length;
  const followers = 0;

  return (
    <ScrollView style={{ flex: 1, backgroundColor: tokens.bg }} contentContainerStyle={styles.content}>
      <View style={{ alignItems: "center", marginBottom: 20 }}>
        <Avatar seed={me.id} label={me.handle || "?"} size={88} />
        <TextInput
          value={me.handle}
          onChangeText={setHandle}
          placeholder="Pick a screen name"
          placeholderTextColor={tokens.mute}
          style={[styles.handleInput, { color: tokens.ink }]}
        />
        <TextInput
          value={me.bio}
          onChangeText={setBio}
          placeholder="Add a bio"
          placeholderTextColor={tokens.mute}
          style={[styles.bioInput, { color: tokens.mute }]}
        />
      </View>

      <View style={styles.stats}>
        <Stat label="Funky Points" value={me.points} />
        <Stat label="Friends" value={friends} />
        <Stat label="Following" value={following} />
        <Stat label="Followers" value={followers} />
      </View>

      <Pressable onPress={() => router.push("/memories")} style={[styles.row, { borderColor: tokens.line }]}>
        <Text style={{ color: tokens.ink, fontWeight: "700" }}>Memories</Text>
        <Text style={{ color: tokens.mute }}>›</Text>
      </Pressable>

      <SectionHeader title="Appearance" />
      <View style={[styles.segment, { backgroundColor: tokens.raised }]}>
        {(["light", "dark", "auto"] as ThemePreference[]).map((opt) => (
          <Pressable
            key={opt}
            onPress={() => setPreference(opt)}
            style={[styles.segBtn, preference === opt && { backgroundColor: tokens.surface }]}
          >
            <Text style={{ color: preference === opt ? tokens.ink : tokens.mute, fontWeight: "700", textTransform: "capitalize" }}>
              {opt}
            </Text>
          </Pressable>
        ))}
      </View>

      <SectionHeader title="Privacy" />
      <Card style={styles.toggleRow}>
        <View style={{ flex: 1 }}>
          <Text style={{ color: tokens.ink, fontWeight: "700" }}>Anonymous mode</Text>
          <Text style={{ color: tokens.mute, fontSize: 12.5, marginTop: 2 }}>Hides your name and profile on chat and Stories.</Text>
        </View>
        <Switch value={me.anon} onValueChange={() => {}} trackColor={{ true: tokens.brand }} />
      </Card>
    </ScrollView>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  const { tokens } = useTheme();
  return (
    <View style={{ alignItems: "center", flex: 1 }}>
      <Text style={{ color: tokens.orange, fontWeight: "800", fontSize: 20 }}>{value}</Text>
      <Text style={{ color: tokens.mute, fontSize: 12 }}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, paddingBottom: 40 },
  handleInput: { fontSize: 20, fontWeight: "800", marginTop: 12, textAlign: "center" },
  bioInput: { fontSize: 14, marginTop: 4, textAlign: "center" },
  stats: { flexDirection: "row", marginBottom: 10 },
  row: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 14, borderBottomWidth: 1 },
  segment: { flexDirection: "row", borderRadius: 10, padding: 3, marginBottom: 8 },
  segBtn: { flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: "center" },
  toggleRow: { flexDirection: "row", alignItems: "center" },
});
