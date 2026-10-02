// Pulled directly from the web prototype's CSS custom properties (index.html)
// so the native app matches it exactly instead of drifting to generic
// React Native defaults. Dark is FUNKY's primary look ("black with the
// orange FUNKY logo"); light is the secondary mode from rule 11.

export type ThemeTokens = {
  bg: string;
  surface: string;
  raised: string;
  line: string;
  ink: string;
  mute: string;
  orange: string;
  brand: string;
  onOrange: string;
  track: string;
  optionText: string;
  map: string;
  mapLine: string;
  you: string;
  gold: string;
  glass: string;
  shade: string;
  danger: string;
};

export const light: ThemeTokens = {
  bg: "#F5F5F7",
  surface: "#FFFFFF",
  raised: "#E8E8ED",
  line: "#D9D9E0",
  ink: "#111114",
  mute: "#676772",
  orange: "#E05600",
  brand: "#FC6401",
  onOrange: "#FFFFFF",
  track: "#E8E8ED",
  optionText: "#111114",
  map: "#E4E4EA",
  mapLine: "#CACAD3",
  you: "#0A84FF",
  gold: "#B87A00",
  glass: "rgba(245,245,247,0.8)",
  shade: "rgba(10,10,14,0.45)",
  danger: "#E0353C",
};

export const dark: ThemeTokens = {
  bg: "#0A0A0C",
  surface: "#17171B",
  raised: "#232329",
  line: "#2E2E36",
  ink: "#FFFFFF",
  mute: "#9B9BA7",
  orange: "#FF7A1A",
  brand: "#FC6401",
  onOrange: "#FFFFFF",
  track: "#1E1E23",
  optionText: "#FFFFFF",
  map: "#16161D",
  mapLine: "#34343F",
  you: "#3B9BFF",
  gold: "#FFC247",
  glass: "rgba(10,10,12,0.78)",
  shade: "rgba(0,0,0,0.6)",
  danger: "#E0353C",
};

/// The "orange to pink to purple" poll-bar gradient (PCOL in the prototype),
/// cycled by option index so a poll with more options just keeps going.
export const pollColors = [
  "#FC6401", // orange (brand)
  "#E0357B", // pink
  "#B03AC8", // magenta
  "#7B3FE4", // purple
  "#5646D8", // indigo
  "#3D4FC9", // blue-indigo
  "#2779CC", // blue
  "#0C8C76", // teal
];

/// Story-ring / handle hue classes (c0..c5 in the prototype), used to give
/// each person's @handle a consistent, distinct color without avatars.
export const handleColors = ["#E0457B", "#8A70FF", "#0E9F86", "#FF7A1A", "#2F8FE8", "#B87A00"];
