import React from "react";
import { Modal, Pressable, Text, View } from "react-native";
import { useTheme } from "@/theme/ThemeContext";
import { useData } from "@/data/store";

/// Rule 2's "New day. New moves." screen — shown once, right after the
/// app notices the stored session is from before the last 4 PM reset.
export function ResetBanner() {
  const { tokens } = useTheme();
  const { justReset, dismissResetBanner } = useData();

  return (
    <Modal visible={justReset} transparent animationType="fade">
      <View style={{ flex: 1, backgroundColor: "rgba(0,0,0,0.6)", alignItems: "center", justifyContent: "center", padding: 24 }}>
        <View style={{ backgroundColor: tokens.surface, borderRadius: 20, padding: 24, width: "100%", maxWidth: 360 }}>
          <Text style={{ color: tokens.orange, fontSize: 22, fontWeight: "800", textAlign: "center" }}>New day. New moves.</Text>
          <Text style={{ color: tokens.mute, marginTop: 12, textAlign: "center" }}>
            Yesterday's chats, places, polls, and Stories have been cleared. Your Stories are saved in Memories.
          </Text>
          <Text style={{ color: tokens.ink, marginTop: 10, textAlign: "center", fontWeight: "600" }}>
            It's a fresh night. What's the move today?
          </Text>
          <Pressable
            onPress={dismissResetBanner}
            style={{ marginTop: 20, backgroundColor: tokens.brand, paddingVertical: 12, borderRadius: 999, alignItems: "center" }}
          >
            <Text style={{ color: tokens.onOrange, fontWeight: "800" }}>Let's go</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}
