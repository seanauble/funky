import React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useTheme } from "@/theme/ThemeContext";
import { pollColors } from "@/theme/colors";

export function PollBars({
  options,
  counts,
  selectedIndex,
  onSelect,
}: {
  options: string[];
  counts: number[];
  selectedIndex: number | null;
  onSelect: (index: number) => void;
}) {
  const { tokens } = useTheme();
  const total = counts.reduce((a, b) => a + b, 0);

  return (
    <View style={{ gap: 8 }}>
      {options.map((label, i) => {
        const pct = total ? Math.round((counts[i] / total) * 100) : 0;
        const widthPct = counts[i] ? Math.max(pct, 6) : 0;
        const color = pollColors[i % pollColors.length];
        const selected = selectedIndex === i;
        return (
          <Pressable
            key={`${label}-${i}`}
            onPress={() => onSelect(i)}
            style={[
              styles.option,
              {
                backgroundColor: tokens.track,
                borderColor: selected ? tokens.ink : "transparent",
              },
            ]}
          >
            <View style={[styles.fill, { width: `${widthPct}%`, backgroundColor: color, opacity: 0.35 }]} />
            <Text style={[styles.label, { color: tokens.optionText }]} numberOfLines={1}>
              {label}
            </Text>
            <Text style={[styles.pct, { color: tokens.optionText }]}>{pct}%</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  option: {
    position: "relative",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    minHeight: 42,
    paddingHorizontal: 12,
    borderRadius: 10,
    borderWidth: 1.5,
    overflow: "hidden",
  },
  fill: {
    position: "absolute",
    left: 0,
    top: 0,
    bottom: 0,
    borderRadius: 10,
  },
  label: { fontWeight: "700", fontSize: 14, flexShrink: 1, marginRight: 8 },
  pct: { fontWeight: "700", fontSize: 13 },
});
