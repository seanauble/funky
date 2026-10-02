import React, { useState } from "react";
import { KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { Chip, EmptyNote, FootNote, Handle } from "@/components/ui";
import { LocationGate } from "@/components/LocationGate";

export default function ChatScreen() {
  const { tokens } = useTheme();
  const { location, roomsForChat, messagesFor, sendMessage, me, people } = useData();
  const [segment, setSegment] = useState<"area" | "dms">("area");
  const [room, setRoom] = useState("main");
  const [draft, setDraft] = useState("");
  const [anon, setAnon] = useState(false);

  return (
    <View style={{ flex: 1, backgroundColor: tokens.bg }}>
      <View style={[styles.segment, { backgroundColor: tokens.raised }]}>
        <SegButton label="Area chat" active={segment === "area"} onPress={() => setSegment("area")} />
        <SegButton label="Messages" active={segment === "dms"} onPress={() => setSegment("dms")} />
      </View>

      {segment === "dms" ? (
        <ScrollView contentContainerStyle={styles.content}>
          <EmptyNote text="No messages yet tonight. Find someone in the chat or on a Story, add them, and plan the pregame." />
          <FootNote text="Private messages and friends stay. Everything else is wiped at 4 PM." />
        </ScrollView>
      ) : !location ? (
        <LocationGate />
      ) : (
        <AreaChat room={room} setRoom={setRoom} />
      )}

      {segment === "area" && location && (
        <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined}>
          <View style={[styles.composer, { backgroundColor: tokens.surface, borderTopColor: tokens.line }]}>
            <Pressable onPress={() => setAnon((a) => !a)} style={[styles.anonBtn, { backgroundColor: anon ? tokens.brand : tokens.raised }]}>
              <Text>👻</Text>
            </Pressable>
            <TextInput
              value={draft}
              onChangeText={setDraft}
              placeholder="Message"
              placeholderTextColor={tokens.mute}
              style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised }]}
              maxLength={240}
            />
            <Pressable
              onPress={() => {
                if (!draft.trim()) return;
                sendMessage(room, draft.trim(), anon);
                setDraft("");
              }}
              style={[styles.sendBtn, { backgroundColor: tokens.brand }]}
            >
              <Ionicons name="arrow-up" color="#fff" size={18} />
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      )}
    </View>
  );
}

function AreaChat({ room, setRoom }: { room: string; setRoom: (r: string) => void }) {
  const { tokens } = useTheme();
  const { roomsForChat, messagesFor, me, people } = useData();
  const msgs = messagesFor(room);
  const activeRoom = roomsForChat.find((r) => r.id === room);

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 10 }}>
        {roomsForChat.map((r) => (
          <View key={r.id} style={{ marginRight: 8 }}>
            <Chip label={r.heat >= 2 ? `${r.name} 🔥` : r.name} active={r.id === room} onPress={() => setRoom(r.id)} />
          </View>
        ))}
      </ScrollView>

      <Text style={{ color: tokens.mute, marginBottom: 10 }}>
        {msgs.length ? "Only people within 25 miles can talk here" : "Nobody has said anything here tonight. Start it off."}
      </Text>

      {msgs.map((m) => (
        <View key={m.id} style={{ marginBottom: 12 }}>
          {m.anon ? (
            <Text style={{ color: tokens.mute, fontSize: 12, marginBottom: 2 }}>anonymous</Text>
          ) : (
            <Handle handle={m.uid === "me" ? me.handle : people[m.uid]?.handle ?? m.uid} />
          )}
          <Text style={{ color: tokens.ink, marginTop: 2 }}>{m.text}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

function SegButton({ label, active, onPress }: { label: string; active: boolean; onPress: () => void }) {
  const { tokens } = useTheme();
  return (
    <Pressable onPress={onPress} style={[styles.segBtn, active && { backgroundColor: tokens.surface }]}>
      <Text style={{ color: active ? tokens.ink : tokens.mute, fontWeight: "700", fontSize: 14 }}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, paddingBottom: 24 },
  segment: { flexDirection: "row", margin: 16, marginBottom: 0, borderRadius: 10, padding: 3 },
  segBtn: { flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: "center" },
  composer: { flexDirection: "row", alignItems: "center", padding: 10, borderTopWidth: 1, gap: 8 },
  anonBtn: { width: 38, height: 38, borderRadius: 19, alignItems: "center", justifyContent: "center" },
  input: { flex: 1, borderRadius: 19, paddingHorizontal: 14, paddingVertical: 9 },
  sendBtn: { width: 38, height: 38, borderRadius: 19, alignItems: "center", justifyContent: "center" },
});
