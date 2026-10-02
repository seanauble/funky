import React from "react";
import { ScrollView, Text, View } from "react-native";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { Card, EmptyNote } from "@/components/ui";

/// Every Story you post is also saved privately here (rule 4). Full
/// "a year ago today" grouping needs more than one real night of history
/// to be meaningful, so for now this lists what you've posted tonight —
/// the grouping and anniversary cards are a near-term follow-up once
/// Stories persist across real nights against a backend.
export default function MemoriesScreen() {
  const { tokens } = useTheme();
  const { myStories } = useData();

  return (
    <ScrollView style={{ flex: 1, backgroundColor: tokens.bg }} contentContainerStyle={{ padding: 16 }}>
      <Text style={{ color: tokens.ink, fontSize: 20, fontWeight: "800", marginBottom: 4 }}>Memories</Text>
      <Text style={{ color: tokens.mute, marginBottom: 16 }}>
        A private archive of your own Stories. Friends, DMs, and this page survive the 4 PM reset — nobody else can see it.
      </Text>
      {myStories.length === 0 ? (
        <Card>
          <EmptyNote text="Nothing saved yet. Post a Story tonight and it'll show up here, even after the reset." />
        </Card>
      ) : (
        myStories.map((s) => (
          <Card key={s.id} style={{ marginBottom: 10 }}>
            <Text style={{ color: tokens.mute, fontSize: 12, marginBottom: 4 }}>{new Date(s.t).toLocaleString()}</Text>
            {s.text ? <Text style={{ color: tokens.ink }}>{s.text}</Text> : <Text style={{ color: tokens.mute }}>Photo story</Text>}
          </Card>
        ))
      )}
    </ScrollView>
  );
}
