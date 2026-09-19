import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

export default function RootLayout() {
  return (
    <>
      <StatusBar style="light" />
      <Stack screenOptions={{ contentStyle: { backgroundColor: '#000' }, headerTintColor: '#fff' }}>
        <Stack.Screen name="index" options={{ headerShown: false }} />
        <Stack.Screen name="join" options={{ title: 'SwarmSight', headerLargeTitle: true, headerStyle: { backgroundColor: '#000' } }} />
        {/* The operator holds the phone up and sweeps: no header, and no swipe-back to leave by accident. */}
        <Stack.Screen name="operator" options={{ headerShown: false, gestureEnabled: false, animation: 'fade' }} />
        <Stack.Screen name="settings" options={{ title: 'Settings', presentation: 'modal', headerStyle: { backgroundColor: '#111' } }} />
      </Stack>
    </>
  );
}
