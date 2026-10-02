import React, { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { PollBars } from "@/components/PollBars";
import { Avatar, Card, Chip, EmptyNote, FootNote, Handle, SectionHeader } from "@/components/ui";
import { LocationGate } from "@/components/LocationGate";

export default function HomeScreen() {
  const { tokens } = useTheme();
  const router = useRouter();
  const {
    me,
    people,
    location,
    rankedPlaces,
    polls,
    messagesFor,
    storiesFor,
    setMove,
    votePoll,
    untilReset,
  } = useData();

  if (!location) return <LocationGate />;

  // "What's the move tonight?" builds itself from the busiest places near
  // you, plus "Staying in" — it is not a stored poll (HANDOFF.md).
  const moveOptions = rankedPlaces.slice(0, 4);
  const moveLabels = [...moveOptions.map((p) => p.name), "Staying in"];
  const moveCounts = [...moveOptions.map((p) => p.going), Object.values({ ...people, me }).filter((p) => p.move === "in").length];
  const moveSelectedIndex = me.move == null ? null : me.move === "in" ? moveOptions.length : moveOptions.findIndex((p) => p.id === me.move);

  const covered = rankedPlaces.filter((p) => p.cover && p.cover.cover > 0);
  const areaMessages = messagesFor("main").slice(-3);

  return (
    <ScrollView style={{ flex: 1, backgroundColor: tokens.bg }} contentContainerStyle={styles.content}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 4 }}>
        <StoryRing label="Your story" onPress={() => router.push("/create")} isAdd me={me} />
        {Object.values(people)
          .filter((p) => storiesFor(p.move ?? "").length)
          .map((p) => (
            <StoryRing key={p.id} label={p.handle} seed={p.id} />
          ))}
      </ScrollView>

      <Card style={{ marginTop: 14 }}>
        <Text style={[styles.question, { color: tokens.mute }]}>WHAT'S THE MOVE TONIGHT?</Text>
        <PollBars
          options={moveLabels}
          counts={moveCounts}
          selectedIndex={moveSelectedIndex}
          onSelect={(i) => setMove(i === moveOptions.length ? "in" : moveOptions[i].id)}
        />
        <Text style={{ color: tokens.mute, fontSize: 12, marginTop: 10, textAlign: "center" }}>
          {moveCounts.reduce((a, b) => a + b, 0)} votes, {untilReset()} left
        </Text>
      </Card>

      <SectionHeader title="Trending nearby" action="See all" onAction={() => router.push("/places")} />
      {rankedPlaces.length === 0 ? (
        <Card>
          <Text style={{ color: tokens.ink, marginBottom: 10 }}>Nothing is listed within 25 miles yet. Put the first spot on the map.</Text>
          <Chip label="Add a place or event" active onPress={() => router.push("/create/place")} />
        </Card>
      ) : (
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          {rankedPlaces.slice(0, 8).map((p) => (
            <Pressable key={p.id} onPress={() => router.push(`/places?focus=${p.id}`)} style={[styles.trendCard, { backgroundColor: tokens.surface, borderColor: tokens.line }]}>
              <View style={[styles.trendCover, { backgroundColor: tokens.raised }]}>
                <Text style={{ fontSize: 22, fontWeight: "800", color: tokens.mute }}>{p.name.slice(0, 1)}</Text>
              </View>
              <Text style={{ color: tokens.ink, fontWeight: "700", marginTop: 8 }} numberOfLines={1}>
                {p.name}
              </Text>
              <Text style={{ color: tokens.orange, fontWeight: "700", fontSize: 12, marginTop: 2 }}>🔥 {p.going} going</Text>
            </Pressable>
          ))}
        </ScrollView>
      )}

      {covered.length > 0 && (
        <>
          <Text style={[styles.h2, { color: tokens.ink }]}>Covers tonight</Text>
          <ScrollView horizontal showsHorizontalScrollIndicator={false}>
            {covered.map((p) => (
              <View key={p.id} style={[styles.covChip, { backgroundColor: tokens.surface, borderColor: tokens.line }]}>
                <Text style={{ color: tokens.orange, fontWeight: "800", fontSize: 18 }}>${p.cover?.cover}</Text>
                <Text style={{ color: tokens.ink, fontSize: 12 }}>{p.name}</Text>
              </View>
            ))}
          </ScrollView>
        </>
      )}

      <SectionHeader title="Area chat" action="Open chat" onAction={() => router.push("/chat")} />
      {areaMessages.length === 0 ? (
        <EmptyNote text="Quiet so far. Be the first to ask what the move is." />
      ) : (
        <Card>
          {areaMessages.map((m) => (
            <View key={m.id} style={{ marginBottom: 8 }}>
              {m.anon ? <Text style={{ color: tokens.mute, fontSize: 12 }}>anonymous</Text> : <Handle handle={people[m.uid]?.handle ?? (m.uid === "me" ? me.handle : m.uid)} />}
              <Text style={{ color: tokens.ink }}>{m.text}</Text>
            </View>
          ))}
        </Card>
      )}

      <SectionHeader title="Polls" action="Ask a poll" onAction={() => router.push("/create/poll")} />
      {polls.length === 0 ? (
        <EmptyNote text="No other polls tonight. Ask the first one." />
      ) : (
        polls.map((poll) => {
          const counts = poll.options.map(() => 0);
          const mine = me.votes[poll.id];
          return (
            <Card key={poll.id} style={{ marginBottom: 10 }}>
              <Text style={{ color: tokens.ink, fontWeight: "700", marginBottom: 8 }}>{poll.q}</Text>
              <PollBars options={poll.options} counts={counts} selectedIndex={mine ?? null} onSelect={(i) => votePoll(poll.id, i)} />
            </Card>
          );
        })
      )}

      <FootNote text={`Chat, Stories, places and polls are wiped at 4 PM. Next fresh start in ${untilReset()}.`} />
    </ScrollView>
  );
}

function StoryRing({
  label,
  isAdd,
  seed,
  me,
  onPress,
}: {
  label: string;
  isAdd?: boolean;
  seed?: string;
  me?: { handle: string };
  onPress?: () => void;
}) {
  const { tokens } = useTheme();
  return (
    <Pressable onPress={onPress} style={styles.ring}>
      <View style={[styles.ringCircle, { borderColor: isAdd ? tokens.line : tokens.orange }]}>
        <Avatar seed={seed ?? label} label={label} size={56} />
        {isAdd && (
          <View style={[styles.plusBadge, { backgroundColor: tokens.brand, borderColor: tokens.bg }]}>
            <Text style={{ color: "#fff", fontWeight: "800", fontSize: 14 }}>+</Text>
          </View>
        )}
      </View>
      <Text style={{ color: tokens.ink, fontSize: 11, marginTop: 4, maxWidth: 64 }} numberOfLines={1}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, paddingBottom: 40 },
  question: { fontWeight: "800", fontSize: 13, letterSpacing: 0.4, marginBottom: 10 },
  h2: { fontSize: 17, fontWeight: "800", marginTop: 18, marginBottom: 8 },
  trendCard: { width: 140, borderRadius: 14, borderWidth: 1, padding: 10, marginRight: 10 },
  trendCover: { height: 80, borderRadius: 10, alignItems: "center", justifyContent: "center" },
  covChip: { borderRadius: 14, borderWidth: 1, padding: 12, marginRight: 10, minWidth: 110 },
  ring: { alignItems: "center", width: 72, marginRight: 8 },
  ringCircle: { width: 64, height: 64, borderRadius: 32, borderWidth: 2.5, alignItems: "center", justifyContent: "center" },
  plusBadge: { position: "absolute", right: -2, bottom: -2, width: 22, height: 22, borderRadius: 11, borderWidth: 2.5, alignItems: "center", justifyContent: "center" },
});
