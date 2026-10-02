import React, { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { useRouter } from "expo-router";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";
import { KindPicker } from "@/components/KindPicker";

export default function CreatePoll() {
  const { tokens } = useTheme();
  const router = useRouter();
  const { addPoll } = useData();
  const [question, setQuestion] = useState("");
  const [options, setOptions] = useState(["", ""]);

  const canPost = question.trim().length > 0 && options.filter((o) => o.trim()).length >= 2;

  const post = () => {
    if (!canPost) return;
    addPoll(question.trim(), options.map((o) => o.trim()).filter(Boolean));
    router.back();
  };

  const updateOption = (i: number, value: string) => {
    setOptions((prev) => prev.map((o, idx) => (idx === i ? value : o)));
  };

  return (
    <View style={[styles.container, { backgroundColor: tokens.bg }]}>
      <KindPicker active="poll" />

      <Text style={{ color: tokens.mute, marginBottom: 6 }}>Question</Text>
      <TextInput
        value={question}
        onChangeText={setQuestion}
        placeholder="Best bar tonight?"
        placeholderTextColor={tokens.mute}
        maxLength={80}
        style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised }]}
      />

      <Text style={{ color: tokens.mute, marginTop: 16, marginBottom: 6 }}>Options</Text>
      {options.map((o, i) => (
        <TextInput
          key={i}
          value={o}
          onChangeText={(v) => updateOption(i, v)}
          placeholder={`Option ${i + 1}`}
          placeholderTextColor={tokens.mute}
          maxLength={40}
          style={[styles.input, { color: tokens.ink, backgroundColor: tokens.raised, marginBottom: 8 }]}
        />
      ))}
      {options.length < 8 && (
        <Pressable onPress={() => setOptions((prev) => [...prev, ""])}>
          <Text style={{ color: tokens.orange, fontWeight: "700" }}>+ Add option</Text>
        </Pressable>
      )}

      <Pressable onPress={post} style={[styles.postBtn, { backgroundColor: tokens.brand, opacity: canPost ? 1 : 0.5 }]}>
        <Text style={{ color: tokens.onOrange, fontWeight: "800" }}>Post poll</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 18 },
  input: { borderRadius: 12, paddingHorizontal: 14, paddingVertical: 12, fontSize: 15 },
  postBtn: { marginTop: 22, paddingVertical: 14, borderRadius: 14, alignItems: "center" },
});
