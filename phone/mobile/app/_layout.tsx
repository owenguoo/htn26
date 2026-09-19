import { DarkTheme, Stack, ThemeProvider } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

/**
 * Routes only, and no colour. The navigator is already a UIKit
 * `UINavigationController` through react-native-screens, so the headers, the
 * large title and the sheet detents are Apple's — the three hardcoded hexes
 * that used to pin them to black are gone.
 *
 * Dark always: `app.json` pins `userInterfaceStyle` and `ThemeController`
 * paints every window. React Navigation follows with `DarkTheme`.
 */
export default function RootLayout() {
  return (
    <ThemeProvider value={DarkTheme}>
      <StatusBar style="light" />
      <Stack>
        <Stack.Screen name="index" options={{ headerShown: false }} />
        <Stack.Screen name="join" options={{ title: 'Beacon', headerLargeTitleEnabled: true }} />
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
