import React from "react";
import { Pressable, View } from "react-native";
import { Tabs, useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "@/theme/ThemeContext";

export default function TabsLayout() {
  const { tokens } = useTheme();
  const router = useRouter();

  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: tokens.orange,
        tabBarInactiveTintColor: tokens.mute,
        tabBarStyle: {
          backgroundColor: tokens.glass,
          borderTopColor: tokens.line,
          height: 60,
        },
        tabBarLabelStyle: { fontSize: 10.5, fontWeight: "600" },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: "Home",
          tabBarIcon: ({ color, size }) => <Ionicons name="home" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="chat"
        options={{
          title: "Chat",
          tabBarIcon: ({ color, size }) => <Ionicons name="chatbubble" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="create"
        options={{
          title: "",
          tabBarIcon: () => null,
          tabBarButton: () => (
            <View style={{ alignItems: "center", justifyContent: "center", flex: 1 }}>
              <Pressable
                onPress={() => router.push("/create")}
                style={{
                  width: 50,
                  height: 50,
                  borderRadius: 25,
                  backgroundColor: tokens.brand,
                  alignItems: "center",
                  justifyContent: "center",
                  shadowColor: tokens.brand,
                  shadowOpacity: 0.45,
                  shadowRadius: 10,
                  shadowOffset: { width: 0, height: 4 },
                  elevation: 4,
                }}
              >
                <Ionicons name="add" color="#fff" size={26} />
              </Pressable>
            </View>
          ),
        }}
        listeners={{
          tabPress: (e) => {
            e.preventDefault();
          },
        }}
      />
      <Tabs.Screen
        name="places"
        options={{
          title: "Places",
          tabBarIcon: ({ color, size }) => <Ionicons name="location" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="profile"
        options={{
          title: "Profile",
          tabBarIcon: ({ color, size }) => <Ionicons name="person" color={color} size={size} />,
        }}
      />
    </Tabs>
  );
}
