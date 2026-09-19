import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useColorScheme } from 'react-native';

/**
 * Routes only, and no colour. The navigator is already a UIKit
 * `UINavigationController` through react-native-screens, so the headers, the
 * large title and the sheet detents are Apple's — the three hardcoded hexes
 * that used to pin them to black are gone.
 *
 * `ThemeProvider` keys React Navigation's own palette off the window's trait
 * collection. `useColorScheme()` follows `overrideUserInterfaceStyle`, which is
 * what `SwarmSight.setTheme()` writes, so the Settings theme picker moves this
 * too. Nothing passes a `colorScheme` prop to a `Host`: omitted, the SwiftUI
 * subtree inherits the same traits.
 */
export default function RootLayout() {
  const scheme = useColorScheme();
  return (
    <ThemeProvider value={scheme === 'light' ? DefaultTheme : DarkTheme}>
      <StatusBar style="auto" />
      <Stack>
        <Stack.Screen name="index" options={{ headerShown: false }} />
        <Stack.Screen name="join" options={{ title: 'SwarmSight', headerLargeTitleEnabled: true }} />
        {/* The operator holds the phone up and sweeps: no header, and no swipe-back to leave by accident. */}
        <Stack.Screen name="operator" options={{ headerShown: false, gestureEnabled: false, animation: 'fade' }} />
        <Stack.Screen
          name="settings"
          options={{
            title: 'Settings',
            presentation: 'formSheet',
            sheetGrabberVisible: true,
            sheetAllowedDetents: [0.6, 1.0],
          }}
        />
      </Stack>
    </ThemeProvider>
  );
}
