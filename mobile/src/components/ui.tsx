import React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useTheme } from "@/theme/ThemeContext";
import { handleColors } from "@/theme/colors";

export function SectionHeader({ title, action, onAction }: { title: string; action?: string; onAction?: () => void }) {
  const { tokens } = useTheme();
  return (
    <View style={styles.rowHead}>
      <Text style={[styles.h2, { color: tokens.ink }]}>{title}</Text>
      {action ? (
        <Pressable onPress={onAction} hitSlop={8}>
          <Text style={[styles.link, { color: tokens.orange }]}>{action}</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

export function Chip({
  label,
  active,
  onPress,
}: {
  label: string;
  active?: boolean;
  onPress?: () => void;
}) {
  const { tokens } = useTheme();
  return (
    <Pressable
      onPress={onPress}
      style={[
        styles.chip,
        { backgroundColor: active ? tokens.brand : tokens.raised },
      ]}
    >
      <Text style={{ color: active ? tokens.onOrange : tokens.ink, fontWeight: "700", fontSize: 13 }} numberOfLines={1}>
        {label}
      </Text>
    </Pressable>
  );
}

export function Card({ children, style }: { children: React.ReactNode; style?: any }) {
  const { tokens } = useTheme();
  return <View style={[styles.card, { backgroundColor: tokens.surface, borderColor: tokens.line }, style]}>{children}</View>;
}

export function EmptyNote({ text }: { text: string }) {
  const { tokens } = useTheme();
  return <Text style={{ color: tokens.mute, paddingVertical: 10 }}>{text}</Text>;
}

export function FootNote({ text }: { text: string }) {
  const { tokens } = useTheme();
  return (
    <Text style={[styles.foot, { color: tokens.mute, borderTopColor: tokens.line }]}>{text}</Text>
  );
}

function hueOf(seed: string): string {
  let h = 0;
  for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) >>> 0;
  return handleColors[h % handleColors.length];
}

export function Avatar({ seed, label, size = 40 }: { seed: string; label: string; size?: number }) {
  const color = hueOf(seed);
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        backgroundColor: color,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <Text style={{ color: "#fff", fontWeight: "800", fontSize: size * 0.4 }}>
        {label.slice(0, 1).toUpperCase()}
      </Text>
    </View>
  );
}

export function Handle({ handle }: { handle: string }) {
  const color = hueOf(handle);
  return <Text style={{ color, fontWeight: "700" }}>@{handle}</Text>;
}

const styles = StyleSheet.create({
  rowHead: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: 18, marginBottom: 8 },
  h2: { fontSize: 17, fontWeight: "800" },
  link: { fontWeight: "700", fontSize: 14 },
  chip: { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 999 },
  card: { borderRadius: 16, borderWidth: 1, padding: 14 },
  foot: { fontSize: 13, marginTop: 24, paddingTop: 14, borderTopWidth: 1 },
});
